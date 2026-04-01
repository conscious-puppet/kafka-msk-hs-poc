module Main where

import AWS.Auth (IAMToken (..))
import Amazonka (Region (..))
import Config (Config (..), loadConfig)
import Config qualified
import Kafka.MSK (KafkaConfig (..), runMSKConsumer)
import Main.Utf8 qualified as Utf8

main :: IO ()
main = Utf8.withUtf8 $ do
  putStrLn "[Main] Starting MSK Kafka Consumer POC with native OAuthBearer"
  putStrLn "[Main] Loading configuration..."
  config <- loadConfig

  putStrLn "[Main] Configuration loaded:"
  putStrLn $ "  Role ARN: " <> toString (Config.awsRoleArn config)
  putStrLn $ "  Bootstrap: " <> toString (Config.mskBootstrapServers config)
  putStrLn $ "  Topic: " <> toString (Config.mskTopic config)
  putStrLn $ "  Region: " <> toString (Config.mskRegion config)

  let kafkaConfig =
        KafkaConfig
          { bootstrapServers = Config.mskBootstrapServers config
          , topic = Config.mskTopic config
          , consumerGroupId = "haskell-msk-consumer-poc"
          , region = Config.mskRegion config
          , awsRoleArn = Config.awsRoleArn config
          , awsSessionName = Config.awsSessionName config
          }

  putStrLn "[Main] Starting consumer with native OAuthBearer authentication..."
  void $ runMSKConsumer kafkaConfig

  putStrLn "[Main] Consumer exited"
