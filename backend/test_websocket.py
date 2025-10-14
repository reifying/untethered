#!/usr/bin/env python3
"""Manual WebSocket testing script for voice-code backend."""

import asyncio
import websockets
import json
import sys

async def test_websocket():
    uri = "ws://localhost:8080"

    try:
        async with websockets.connect(uri) as websocket:
            print("✓ Connected to", uri)

            # Receive welcome message
            message = await websocket.recv()
            data = json.loads(message)
            print(f"✓ Welcome: {data}")
            assert data['type'] == 'connected'

            # Test ping
            await websocket.send(json.dumps({"type": "ping"}))
            response = await websocket.recv()
            data = json.loads(response)
            print(f"✓ Ping response: {data}")
            assert data['type'] == 'pong'

            # Test set-directory
            await websocket.send(json.dumps({
                "type": "set-directory",
                "path": "/tmp/test"
            }))
            response = await websocket.recv()
            data = json.loads(response)
            print(f"✓ Set directory: {data}")
            assert data['type'] == 'ack'

            # Test prompt (will get ack since Claude not implemented yet)
            await websocket.send(json.dumps({
                "type": "prompt",
                "text": "Hello, Claude!"
            }))
            response = await websocket.recv()
            data = json.loads(response)
            print(f"✓ Prompt response: {data}")
            assert data['type'] == 'ack'

            # Test unknown message type
            await websocket.send(json.dumps({"type": "unknown"}))
            response = await websocket.recv()
            data = json.loads(response)
            print(f"✓ Error handling: {data}")
            assert data['type'] == 'error'

            print("\n✅ All manual tests passed!")

    except Exception as e:
        print(f"❌ Test failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(test_websocket())
