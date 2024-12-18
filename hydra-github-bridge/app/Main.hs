{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE TypeApplications  #-}
{-# language TypeOperators     #-}
{-# language DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}

module Main where

import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Notification
import Data.Char (toLower)
import Control.Concurrent
import Control.Monad
import Control.Exception (catch, displayException, SomeException)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import GHC.Generics
import Data.Text (Text)
import Data.Text.Lazy (toStrict)
import System.Environment (lookupEnv)
import Control.Concurrent.STM (newTChan, atomically)
import Control.Concurrent.STM (newTVarIO, TChan, readTChan, writeTChan, atomically)

import qualified Data.Aeson as Aeson
import           Data.Aeson hiding (Success, Error)
import           Data.Aeson.Text (encodeToLazyText)
import           Data.Aeson.Casing
import Servant.Client
import           Data.Proxy
import           Servant.API
import           Network.HTTP.Client (newManager, defaultManagerSettings)
import           Network.HTTP.Client.TLS (tlsManagerSettings)

import System.IO (hSetBuffering, stdin, stdout, stderr, BufferMode(LineBuffering))

-- Data Types
type JobSetId = Int
type EvalRecordId = Int

data HydraNotification
    = EvalStarted JobSetId
    | EvalAdded JobSetId EvalRecordId
    | EvalCached JobSetId EvalRecordId
    | EvalFailed JobSetId
    deriving (Show, Eq)

data StatusState = Error | Failure | Pending | Success
    deriving (Show, Eq, Generic)

instance ToJSON StatusState where
  toJSON = genericToJSON toLowerModifier

instance FromJSON StatusState where
  parseJSON = genericParseJSON toLowerModifier

-- Downcase the first letter of JSON values
toLowerModifier :: Options
toLowerModifier = defaultOptions { constructorTagModifier = modifier }
    where
      modifier (s:ss) = toLower s : ss
      modifier [] = []

data GitHubStatusPayload
    = GitHubStatusPayload
    { state :: StatusState
    , target_url :: Text
    , description :: Maybe Text
    , context :: Text
    } deriving (Show, Eq, Generic)

instance ToJSON GitHubStatusPayload where
    toJSON = genericToJSON $ aesonDrop 0 camelCase

instance FromJSON GitHubStatusPayload where
    parseJSON = genericParseJSON $ aesonDrop 0 camelCase


-- The following table exists in the databse:
--
-- CREATE TABLE github_status (
--     id SERIAL,
--     owner TEXT NOT NULL,
--     repo TEXT NOT NULL,
--     sha TEXT NOT NULL,
--     payload JSONB NOT NULL,
--     created TIMESTAMP DEFAULT NOW(),
--     sent TIMESTAMP DEFAULT NULL,
--     PRIMARY KEY (id)
-- );

data GitHubStatus
    = GitHubStatus
    { owner :: Text
    , repo :: Text
    , sha :: Text
    , payload :: GitHubStatusPayload
    }
    deriving (Show, Eq, Generic)

instance ToJSON GitHubStatus where
  toJSON = genericToJSON $ aesonDrop 0 camelCase

instance FromJSON GitHubStatus where
  parseJSON = genericParseJSON $ aesonDrop 0 camelCase

-- Text utils
tshow :: Show a => a -> Text
tshow = Text.pack . show

-- split github:<owner>/<repo>/<hash> into (owner, repo, hash)
-- this is such a god aweful hack!
parseGitHubFlakeURI :: Text -> Maybe (Text, Text, Text)
parseGitHubFlakeURI uri | "github:" `Text.isPrefixOf` uri =
    case Text.splitOn "/" (Text.drop 7 uri) of
        -- TODO: hash == 40 is a _very_ poor approximation to ensure this is a sha
        (owner:repo:hash:[]) | Text.length hash == 40 -> Just (owner, repo, hash)
        _                    -> Nothing
parseGitHubFlakeURI _ = Nothing

toHydraNotification :: Notification -> HydraNotification
toHydraNotification Notification { notificationChannel = chan, notificationData = payload}
    | chan == "eval_started" = let [_, jid]      = words (BS.unpack payload) in EvalStarted (read jid)
    | chan == "eval_added"   = let [_, jid, eid] = words (BS.unpack payload) in EvalAdded (read jid) (read eid)
    | chan == "eval_cached"  = let [_, jid, eid] = words (BS.unpack payload) in EvalCached (read jid) (read eid)
    | chan == "eval_failed"  = let [_, jid]      = words (BS.unpack payload) in EvalFailed (read jid)

handleHydraNotification :: Connection -> HydraNotification -> IO (Maybe GitHubStatus)
handleHydraNotification conn e = flip catch (handler e) $ case e of
    (EvalStarted jid) -> do
        [(proj, name, flake)] <- query conn "select project, name, flake from jobsets where id = ?" (Only jid)
        Text.putStrLn $ "Eval Started (" <> tshow jid <> "): " <> (proj :: Text) <> ":" <> (name :: Text) <> " " <> tshow flake
        case parseGitHubFlakeURI flake of
            Just (owner, repo, hash) -> pure $ Just (GitHubStatus owner repo hash (GitHubStatusPayload Pending {- target url: -} ("https://ci.zw3rk.com/jobset/" <> proj <> "/" <> name) {- description: -} Nothing "ci/eval"))
            _ -> pure $ Nothing
    (EvalAdded jid eid) -> do
        [(proj, name, flake, errmsg, fetcherrmsg)] <- query conn "select project, name, flake, errormsg, fetcherrormsg from jobsets where id = ?" (Only jid)
        [(Only flake')] <- query conn "select flake from jobsetevals where id = ?" (Only eid)
        Text.putStrLn $ "Eval Added (" <> tshow jid <> ", " <> tshow eid <> "): " <> (proj :: Text) <> ":" <> (name :: Text) <> " " <> flake <> " eval for: " <> flake'
        case parseGitHubFlakeURI flake of
            Just (owner, repo, hash) -> pure $ case (errmsg, fetcherrmsg) :: (Maybe Text, Maybe Text) of
                (Just err,_) | not (Text.null err) -> Just (GitHubStatus owner repo hash (GitHubStatusPayload Failure {- target url: -} ("https://ci.zw3rk.com/eval/" <> tshow eid <> "#tabs-errors") {- description: -} (Just "Evaluation has errors.") "ci/eval"))
                (_,Just err) | not (Text.null err) -> Just (GitHubStatus owner repo hash (GitHubStatusPayload Failure {- target url: -} ("https://ci.zw3rk.com/eval/" <> tshow eid <> "#tabs-errors") {- description: -} (Just "Failed to fetch.") "ci/eval"))
                _            -> Just (GitHubStatus owner repo hash (GitHubStatusPayload Success {- target url: -} ("https://ci.zw3rk.com/eval/" <> tshow eid) {- description: -} Nothing "ci/eval"))
            _ -> pure $ Nothing
    (EvalCached jid eid) -> do
        [(proj, name, flake, errmsg, fetcherrmsg)] <- query conn "select project, name, flake, errormsg, fetcherrormsg from jobsets where id = ?" (Only jid)
        [(Only flake')] <- query conn "select flake from jobsetevals where id = ?" (Only eid)
        Text.putStrLn $ "Eval Cached (" <> tshow jid <> ", " <> tshow eid <> "): " <> (proj :: Text) <> ":" <> (name :: Text) <> " " <> flake <> " eval for: " <> flake'
        case parseGitHubFlakeURI flake of
            Just (owner, repo, hash) -> pure $ case (errmsg, fetcherrmsg) :: (Maybe Text, Maybe Text) of
                (Just err,_) | not (Text.null err) -> Just (GitHubStatus owner repo hash (GitHubStatusPayload Failure {- target url: -} ("https://ci.zw3rk.com/eval/" <> tshow eid <> "#tabs-errors") {- description: -} (Just "Evaluation has errors.") "ci/eval"))
                (_,Just err) | not (Text.null err) -> Just (GitHubStatus owner repo hash (GitHubStatusPayload Failure {- target url: -} ("https://ci.zw3rk.com/eval/" <> tshow eid <> "#tabs-errors") {- description: -} (Just "Failed to fetch.") "ci/eval"))
                _            -> Just (GitHubStatus owner repo hash (GitHubStatusPayload Success {- target url: -} ("https://ci.zw3rk.com/eval/" <> tshow eid) {- description: -} Nothing "ci/eval"))
            _ -> pure $ Nothing
    (EvalFailed jid) -> do
        [(proj, name, flake)] <- query conn "select project, name, flake from jobsets where id = ?" (Only jid)
        Text.putStrLn $ "Eval Failed (" <> tshow jid <> "): " <> (proj :: Text) <> ":" <> (name :: Text) <> " " <> tshow (parseGitHubFlakeURI flake)
        case parseGitHubFlakeURI flake of
            Just (owner, repo, hash) -> pure $ Just (GitHubStatus owner repo hash (GitHubStatusPayload Failure {- target url: -} ("https://ci.zw3rk.com/jobset/" <> proj <> "/" <> name) {- description: -} Nothing "ci/eval"))
            _ -> pure $ Nothing
    _ -> print e >> pure Nothing

  where handler :: HydraNotification -> SomeException -> IO (Maybe GitHubStatus)
        handler n ex = print (show n ++ " triggert exception " ++ displayException ex) >> pure Nothing

-- GitHub Status PI
-- /repos/{owner}/{repo}/statuses/{sha} with
-- {"state":"success"
--  ,"target_url":"https://example.com/build/status"
--  ,"description":"The build succeeded!"
--  ,"context":"continuous-integration/jenkins"
-- }
type GitHubAPI = "repos"
                 :> Header "User-Agent" Text
                 :> Header "Accept" Text -- "application/vnd.github+json"
                 :> Header "Authorization" Text -- token <pat> / Bearer ...
                 :> Header "X-GitHub-Api-Version" Text -- "2022-11-28"
                 :> Capture "owner" Text
                 :> Capture "repo" Text
                 :> "statuses"
                 :> Capture "sha" Text
                 :> ReqBody '[JSON] GitHubStatusPayload
                 :> PostCreated '[JSON] Value

-- Auth (Bearer <YOUR-TOKEN>)
-- owner, repo, sha, Status
mkStatus :: Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Text -> Text -> Text -> GitHubStatusPayload -> ClientM Value

mkStatus = client (Proxy @GitHubAPI)

-- TODO: What do we do if the request fails?
sendStatusToGitHub :: Text -> GitHubStatus -> IO ()
sendStatusToGitHub token status = do
    manager <- newManager tlsManagerSettings
    let env = (mkClientEnv manager (BaseUrl Https "api.github.com" 443 ""))
    putStrLn $ BSL.unpack $ encode (payload status)
    resp <- flip runClientM env $ do
        mkStatus (Just "hydra-github-bridge")
                 (Just "application/vnd.github+json")
                 (Just token)
                 (Just "2022-11-28")
                 (owner status)
                 (repo status)
                 (sha status)
                 (payload status)

    case resp of
      Left err -> Text.putStrLn $ "Could not send status to GitHub: " <> tshow (displayException err)
      Right _ -> pure ()

saveStatusToDb :: Connection -> GitHubStatus -> IO Int
saveStatusToDb conn status = do
    let q = "insert into github_status (owner, repo, sha, payload) values (?, ?, ?, ?) returning id"
    [Only id'] <- query conn q (owner status, repo status, sha status, encode (payload status))
    pure id'

lookupStatusFromDB :: Connection -> Int -> IO (Maybe GitHubStatus)
lookupStatusFromDB conn id' = do
    let q = "select owner, repo, sha, payload from github_status where id = ?"
    [(owner', repo', sha', payload')] <- query conn q (Only id')

    case fromJSON payload' of
        Aeson.Success p -> do
          pure $ Just (GitHubStatus owner' repo' sha' p)
        Aeson.Error err -> do
          Text.putStrLn $ "Could not parse status: " <> toStrict (encodeToLazyText payload')
          pure Nothing

-- For each new status, run the procedure:
--
--  1. Save the status to a Hydra table
--  2. Send it to GitHub
--  3. Delete it from the Hydra table
--
-- TODO: What do we do with statuses left in the database?
handleStatus :: Connection -> Text -> GitHubStatus -> IO ()
handleStatus conn token status = do
    id' <- saveStatusToDb conn status
    void . forkIO $
      lookupStatusFromDB conn id' >>= \case
        Just status -> sendStatusToGitHub token status
        Nothing -> pure ()

-- Main
main :: IO ()
main = do

    hSetBuffering stdin LineBuffering
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering

    host <- maybe "localhost" id <$> lookupEnv "HYDRA_HOST"
    user <- maybe mempty id <$> lookupEnv "HYDRA_USER"
    pass <- maybe mempty id <$> lookupEnv "HYDRA_PASS"
    token <- maybe mempty Text.pack <$> lookupEnv "GITHUB_TOKEN"
    queue <- atomically $ newTChan

    withConnect (ConnectInfo host 5432 user pass "hydra") $ \conn -> do
        _ <- execute_ conn "LISTEN eval_started" -- (opaque id, jobset id)
        _ <- execute_ conn "LISTEN eval_added"   -- (opaque id, jobset id, eval record id)
        _ <- execute_ conn "LISTEN eval_cached"  -- (opaque id, jobset id, prev identical eval id)
        _ <- execute_ conn "LISTEN eval_failed"  -- (opaque id, jobset id)

        forever $ do
            note <- toHydraNotification <$> getNotification conn
            handleHydraNotification conn note >>= \case
                Just status -> handleStatus conn token status
                Nothing -> pure ()
