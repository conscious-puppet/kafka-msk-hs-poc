module Main where

import AWS.Auth (assumeRole, isAuthError, startTokenRefresher)
import Amazonka (Region (..))
import Config (Config (..), loadConfig)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel)
import Kafka.MSK (KafkaConfig (..), runMSKConsumer)
import Main.Utf8 qualified as Utf8

{- | Convert region text to Amazonka Region type
Region is just a newtype wrapper around Text, so we construct it directly
-}
regionFromText :: Text -> Region
regionFromText = Region'

main :: IO ()
main = Utf8.withUtf8 $ do
  putStrLn "[Main] Starting MSK Kafka Consumer POC"
  putStrLn "[Main] Loading configuration..."
  config <- loadConfig

  putStrLn "[Main] Configuration loaded:"
  putStrLn $ "  Role ARN: " <> toString (awsRoleArn config)
  putStrLn $ "  Bootstrap: " <> toString (mskBootstrapServers config)
  putStrLn $ "  Topic: " <> toString (mskTopic config)
  putStrLn $ "  Region: " <> toString (mskRegion config)

  -- Convert region text to Region type
  let region = regionFromText (mskRegion config)

  -- Supervisor loop: handles reconnections on auth errors
  void $ infinitely $ do
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

    putStrLn "[Main] Starting consumer (will reconnect on auth errors)..."
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
