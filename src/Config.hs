module Config (
  Config (..),
  loadConfig,
)
where

import Control.Exception (throwIO)
import Data.Text qualified as T
import System.IO.Error (userError)

data Config = Config
  { awsRoleArn :: Text
  , awsSessionName :: Text
  , mskBootstrapServers :: Text
  , mskTopic :: Text
  , mskRegion :: Text
  }
  deriving stock (Show, Eq)

loadConfig :: IO Config
loadConfig = do
  awsRoleArn <- getEnvVar "AWS_ROLE_ARN"
  awsSessionName <- fromMaybe "kafka-haskell-poc" <$> lookupEnvText "AWS_SESSION_NAME"
  mskBootstrapServers <- getEnvVar "MSK_BOOTSTRAP_SERVERS"
  mskTopic <- getEnvVar "MSK_TOPIC"
  mskRegion <- fromMaybe "ap-south-1" <$> lookupEnvText "MSK_REGION"
  pure Config {..}

getEnvVar :: String -> IO Text
getEnvVar name =
  lookupEnv name >>= \case
    Nothing -> throwIO $ userError $ "Environment variable " <> name <> " is required"
    Just val -> pure $ T.pack val

lookupEnvText :: String -> IO (Maybe Text)
lookupEnvText name = fmap T.pack <$> lookupEnv name
