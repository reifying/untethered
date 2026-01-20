Study docs/design/clojurescript-react-native-pilot.md and and explore the codebase to understand what has been done and what remains. Run `bd list` to identify what backlog has been reported. If there are no applicable tasks ready to work, thoroughly search the code base to look for additional parity gaps and document them with beads tasks. It is your job to determine the what is important to work on next to deliver a high quality, finished platform-agnostic mobile app.

Use a subagent to run the tests. If the react-native test frameworks are not in place yet, it is your job to build them using subagents. If any tests are failing, it is your job to fix them by correcting the implementation or improving the test. If the tests are slow, it is your job to refactor the code or tests as needed to improve the speed of our feedback loop.

You are responsible for determining whether the implementation has exceeded the design document and needs to be course-corrected. The design is attempting to achieve parity in the new platform-agnostic app with the original iOS/Mac app. After verifying the beads task does not already exist, create new beads issues for any gaps you discover that aren't already tracked. Example questions you should be asking as you go along include:
- What does the iOS app do that I haven't seen evidence of in the RN code?
- Are there iOS views/features with no RN equivalent?
- Are there subtle behaviors (edge cases, error handling, animations) that differ?
- Do the existing beads issues actually capture all the gaps, or are there undiscovered ones?

**Important** Do not trust previous assessments that the work is 'done' - verify independently

You can add new libraries but have a subagent perform a security analysis to ensure that the libraries you have added are not going to compromise our application or dev environment.

Before implementing any feature:
1. Find the iOS implementation - Locate the equivalent Swift file in `ios/VoiceCode/`
2. Verify it's wired up - Model stubs don't count. The feature must be:
   - Parsed from WebSocket responses
   - Stored in CoreData (if persistent)
   - Displayed in the UI
3. Match exactly - Don't enhance or "complete" partially-implemented iOS features
4. If iOS is incomplete - Create a parity gap issue, don't implement the RN version

The iOS app is the reference implementation. If a field exists in iOS models but isn't displayed in iOS views, it's not ready for RN implementation.

Use beads (run `bd quickstart` to learn about beads) to track the work for your session. Open beads for the work you will perform. Make sure the beads are updated before your turn is finished. Cite the `ios/VoiceCode/` used as a refernence for your implementation in your updates to the bead task before closing. If there are any P0 bugs, those have the highest priority since they indicate issues in recent work.

You can use up to 1000 tool calls to complete this work. Use up to 1000 parallel subagents, but only use 1 subagent for compiling and running tests.

When tests pass, manually verify functionality on the simulator before committing. Use `/cljs-repl` for REPL-driven development, `/repl-ui-testing` for programmatic navigation and screenshots, and `/ui-test-agent` for systematic UI testing.

When tests pass and manual verification is complete, have a haiku subagent commit, tag, and push.

Your session should result in either: (a) implementation of existing bead issues or (b) new issues created from parity gaps discovered.

Be sure to verify the beads task does not already exist before creating a new task.

Reminder: Run `bd list`. If there is a P0 bug, it is your job to fix that bug rather than work on the remaining parity items.
