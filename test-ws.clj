#!/usr/bin/env bb

(require '[clojure.string :as str])
(require '[cheshire.core :as json])

;; Simple WebSocket test client
(println "Testing WebSocket connection to ws://localhost:8080")

;; Use curl to test WebSocket upgrade
(let [result (sh "curl" "-i" "-N" "-H" "Connection: Upgrade"
                  "-H" "Upgrade: websocket"
                  "-H" "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw=="
                  "-H" "Sec-WebSocket-Version: 13"
                  "http://localhost:8080")]
  (println "Response:")
  (println (:out result))
  (println (:err result)))
