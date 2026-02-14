Find something to improve in how our CLJS React Native app (`./frontend/**`) looks and feels natively on iOS and Android. We are replacing our Swift iOS app (`./ios/**`) with a React Native cross-platform equivalent (at `./frontend`), and the new app should feel at home on each platform — not like a web app wearing a native costume.

Our code standards adopt `/Users/travisbrown/code/clojure-style-guide/README.adoc`

The design doc can be referenced at `docs/design/clojurescript-react-native-pilot.md`

Run `bd quickstart` to understand how to create/update beads tasks to track progress and communicate your work. Before creating any beads tasks, make sure they do not exist.

Your primary job is to make the app feel like it belongs on each platform — the things a user notices when something feels off even if they can't articulate why. Native feel polish takes priority over new feature work. Review CLAUDE.md for platform conventions. We have not done much manual testing yet so any code in `./frontend/**` is still suspect. Any bug fix or refactors need to ensure we still have parity with the iOS original implementation within reason.

Use a subagent to run the tests. If the test frameworks are not in place yet, it is your job to build them using subagents. If any tests are failing, it is your job to fix them by correcting the implementation or improving the test. If the tests are slow, it is your job to refactor the code or tests as needed to improve the speed of our feedback loop.

You are responsible for determining whether the implementation has exceeded the design document and needs to be course-corrected. The design is attempting to achieve parity in the new platform-agnostic app with the original iOS/Mac app.

**Important** Do not trust previous assessments that the work is 'done' - verify independently

You can add new libraries but have a subagent perform a security analysis to ensure that the libraries you have added are not going to compromise our application or dev environment.

Before implementing any new feature:
1. Find the iOS implementation - Locate the equivalent Swift file in `ios/VoiceCode/`
2. Verify it's wired up - Model stubs don't count. The feature must be:
   - Parsed from WebSocket responses
   - Stored in CoreData (if persistent)
   - Displayed in the UI
3. Match exactly - Don't enhance or "complete" partially-implemented iOS features
4. If iOS is incomplete - Create a parity gap issue, don't implement the RN version

The iOS app is the reference implementation for features. If a field exists in iOS models but isn't displayed in iOS views, it's not ready for RN implementation. Platform-specific native feel work (Android ripple effects, Material typography, etc.) does not require iOS parity — each platform has its own conventions.

One option among several to consider is to check our test coverage. Install coverage framework if it does not exist and add a Makefile command. The coverage tool is slower so should only be run intentionally when trying to understand testing gaps. Ideally, the way our report is generated produces output that does not fill an agent's context window.

Make sure the beads are updated before your turn is finished. Cite the `ios/VoiceCode/` used as a reference for your implementation in your updates to the bead task before closing. If there are any P0 bugs, those have the highest priority since they indicate issues in recent work.

You can use up to 1000 tool calls to complete this work. Use up to 1000 parallel subagents, but only use 1 subagent for compiling and running tests.

When tests pass, manually verify functionality on the simulator before committing. Take screenshots on both iOS and Android — platform rendering differences are real and frequent. Use `/cljs-repl` for REPL-driven development, `/repl-ui-testing` for programmatic navigation and screenshots, and `/ui-test-agent` for systematic UI testing.

When tests pass and manual verification is complete, commit and push.

Your session should result in the implementation of a beads task (either one you created or an existing one that you deemed high priority). When your turn ends, cite the 1-3 iOS source files that were most important for comparing to your work to ensure parity.
