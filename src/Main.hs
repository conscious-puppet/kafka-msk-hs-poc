module Main where

import AWS.Auth (assumeRole, isAuthError, startTokenRefresher)
import Amazonka (Region)
import Config (Config (..), loadConfig)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel)
import Data.Text qualified as T
import Kafka.MSK (KafkaConfig (..), runMSKConsumer)
import Main.Utf8 qualified as Utf8

-- | Parse a region string into Amazonka Region type
parseRegion :: String -> Either Text Region
parseRegion s = case readEither s of
  Left e -> Left e
  Right r -> Right r

main :: IO ()
main = Utf8.withUtf8 $ do
  putStrLn "[Main] Starting MSK Kafka Consumer POC"
  putStrLn "[Main] Loading configuration..."
  config <- loadConfig

  putStrLn $ "[Main] Configuration loaded:"
  putStrLn $ "  Role ARN: " <> T.unpack (awsRoleArn config)
  putStrLn $ "  Bootstrap: " <> T.unpack (mskBootstrapServers config)
  putStrLn $ "  Topic: " <> T.unpack (mskTopic config)
  putStrLn $ "  Region: " <> T.unpack (mskRegion config)

  -- Parse region
  region <- case parseRegion (T.unpack $ mskRegion config) of
    Left err -> error $ "[Main] Invalid region: " <> err
    Right r -> pure r

  -- Supervisor loop: handles reconnections on auth errors
  void $ forever $ do
    putStrLn "\n[Main] === Starting new connection cycle ==="

    -- Step 1: Assume role via STS
    putStrLn "[Main] Assuming role via STS..."
    initialToken <- assumeRole (awsRoleArn config) (awsSessionName config) region
    putStrLn "[Main] Role assumed successfully"

    -- Step 2: Create TVar with initial token
    tokenVar <- newTVarIO initialToken

    -- Step 3: Start token refresher (every 10 seconds)
    putStrLn "[Main] Starting token refresher thread..."
    refresher <- startTokenRefresher tokenVar (awsRoleArn config) (awsSessionName config) region

    -- Step 4: Run consumer
    let kafkaConfig =
          KafkaConfig
            { bootstrapServers = mskBootstrapServers config
            , topic = mskTopic config
            , consumerGroupId = "haskell-msk-consumer-poc"
            , region = mskRegion config
            }

    putStrLn $ "[Main] Starting consumer (will reconnect on auth errors)..."
    result <- runMSKConsumer kafkaConfig tokenVar

    -- Step 5: Consumer returned (either auth error or fatal error)
    putStrLn "[Main] Consumer stopped, cancelling refresher..."
    cancel refresher

    case result of
      Left err | isAuthError err -> do
        putStrLn $ "[Main] Authentication error detected: " <> show err
        putStrLn "[Main] Will reconnect with fresh token in 2 seconds..."
        threadDelay (2 * 1000000) -- Wait 2 seconds before reconnect
        putStrLn "[Main] Reconnecting now..."
      Left err -> do
        putStrLn $ "[Main] Fatal error, crashing: " <> show err
        exitFailure
      Right () -> do
        putStrLn "[Main] Consumer exited normally (unexpected), restarting..."
        threadDelay (2 * 1000000)

  putStrLn "[Main] Exiting (should never reach here)"
