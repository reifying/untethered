Read docs/design/clojurescript-react-native-pilot.md and explore the code base.

Study docs/design/clojurescript-react-native-pilot.md and and explore the codebase to understand what has been done and what remains. Determine the what is important to work on next to deliver a high quality, finished platform-agnostic mobile app.

Use a subagent to run the tests. If the react-native test frameworks are not in place yet, it is your job to build them using subagents. If any tests are failing, it is your job to fix them by correcting the implementation or improving the test. If the tests are slow, it is your job to refactor the code or tests as needed to improve the speed of our feedback loop.

You are responsible for determining whether the implementation has exceeded the design document and needs to be course-corrected. The design is attempting to achieve parity in the new platform-agnostic app with the original iOS/Mac app.

You can add new libraries but have a subagent perform a security analysis to ensure that the libraries you have added are not going to compromise our application or dev environment.

Use beads (run `bd quickstart` to learn about beads) to track the work for your session. Open beads for the work you will perform. Make sure the beads are updated before your turn is finished.

You can use up to 1000 tool calls to complete this work. Use up to 1000 parallel subagents, but only use 1 subagent for compiling and running tests.

When tests pass, have a haiku subagent commit, tag, and push.
