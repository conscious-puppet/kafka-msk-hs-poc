module Main where

import Config (Config (..), loadConfig)
import Kafka.MSK (KafkaConfig (..), runMSKConsumer)
import Main.Utf8 qualified as Utf8

main :: IO ()
main = Utf8.withUtf8 $ do
  putStrLn "[Main] Starting MSK Kafka Consumer POC"
  putStrLn "[Main] Loading configuration..."
  config <- loadConfig

  putStrLn "[Main] Configuration loaded:"
  putStrLn $ "  Bootstrap: " <> toString (mskBootstrapServers config)
  putStrLn $ "  Topic: " <> toString (mskTopic config)
  putStrLn $ "  Region: " <> toString (mskRegion config)

  let kafkaConfig =
        KafkaConfig
          { bootstrapServers = mskBootstrapServers config
          , topic = mskTopic config
          , consumerGroupId = "haskell-msk-consumer-poc"
          , region = mskRegion config
          }

  putStrLn "[Main] Starting consumer..."
  void $ runMSKConsumer kafkaConfig

  putStrLn "[Main] Consumer exited"
