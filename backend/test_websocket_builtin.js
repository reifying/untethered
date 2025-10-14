#!/usr/bin/env node
/**
 * WebSocket integration test for voice-code backend
 * Uses Node.js built-in WebSocket API (Node v21+)
 */

const SERVER_URL = 'ws://localhost:8080';
const TIMEOUT = 10000;

let testsPassed = 0;
let testsFailed = 0;

function assert(condition, message) {
  if (condition) {
    console.log(`✓ ${message}`);
    testsPassed++;
  } else {
    console.error(`✗ ${message}`);
    testsFailed++;
    throw new Error(`Assertion failed: ${message}`);
  }
}

async function runTests() {
  console.log(`Connecting to ${SERVER_URL}...\n`);

  const ws = new WebSocket(SERVER_URL);
  const messages = [];

  // Collect all messages
  ws.addEventListener('message', (event) => {
    const msg = JSON.parse(event.data);
    messages.push(msg);
    console.log(`← Received: ${JSON.stringify(msg, null, 2)}`);
  });

  // Wait for connection
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve);
    ws.addEventListener('error', (e) => reject(new Error('Connection error')));
    setTimeout(() => reject(new Error('Connection timeout')), TIMEOUT);
  });

  console.log('✓ WebSocket connected\n');

  // Helper to send and wait for response
  const sendAndWait = (message, expectedType, timeout = 5000) => {
    return new Promise((resolve, reject) => {
      const startCount = messages.length;
      console.log(`→ Sending: ${JSON.stringify(message)}`);

      ws.send(JSON.stringify(message));

      const startTime = Date.now();

      const checkResponse = () => {
        const newMessages = messages.slice(startCount);
        const response = newMessages.find(m => m.type === expectedType);

        if (response) {
          resolve(response);
        } else if (Date.now() - startTime > timeout) {
          reject(new Error(`Timeout waiting for ${expectedType}`));
        } else {
          setTimeout(checkResponse, 100);
        }
      };

      setTimeout(checkResponse, 100);
    });
  };

  try {
    // Test 1: Receive welcome message
    await new Promise(resolve => setTimeout(resolve, 500));
    const welcome = messages.find(m => m.type === 'connected');
    assert(welcome, 'Received welcome message');
    assert(welcome.message.includes('Welcome'), 'Welcome message has correct text');
    assert(welcome.version === '0.1.0', 'Version is correct');

    // Test 2: Ping/Pong
    const pong = await sendAndWait({ type: 'ping' }, 'pong');
    assert(pong.type === 'pong', 'Received pong response');

    // Test 3: Set directory
    const dirResponse = await sendAndWait(
      { type: 'set-directory', path: '/tmp/test' },
      'ack'
    );
    assert(dirResponse.type === 'ack', 'Received ack for set-directory');
    assert(
      dirResponse.message.includes('/tmp/test'),
      'Set-directory response contains path'
    );

    // Test 4: Prompt (should receive ack immediately)
    const promptAck = await sendAndWait(
      { type: 'prompt', text: 'Hello, Claude!' },
      'ack'
    );
    assert(promptAck.type === 'ack', 'Received ack for prompt');
    assert(
      promptAck.message.includes('Processing'),
      'Ack message indicates processing'
    );

    // Note: We won't wait for the actual Claude response in this test
    // since it requires Claude CLI to be installed and configured

    // Test 5: Unknown message type (error handling)
    const errorResponse = await sendAndWait(
      { type: 'unknown-type' },
      'error'
    );
    assert(errorResponse.type === 'error', 'Received error for unknown type');
    assert(
      errorResponse.message.includes('Unknown'),
      'Error message indicates unknown type'
    );

    console.log('\n✅ All tests passed!');
    console.log(`   ${testsPassed} passed, ${testsFailed} failed`);

    ws.close();
    process.exit(0);
  } catch (error) {
    console.error(`\n❌ Test failed: ${error.message}`);
    console.log(`   ${testsPassed} passed, ${testsFailed} failed`);
    ws.close();
    process.exit(1);
  }
}

runTests().catch((error) => {
  console.error(`\n❌ Fatal error: ${error.message}`);
  process.exit(1);
});
