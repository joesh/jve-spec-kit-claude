
I would like to set up two test environments. Both will run off a set of JSON-based test descriptions that set up the test and detail expected outcomes.
One is like we have now - where tests can be run very quickly in the mocked and stubbed environment. The other runs the tests on the actual running JVE app. 

I would also like to take the current hand-coded regression tests and convert them into this format.

I would also like to set up a situation where when I'm running the JVE app and something bad happens, the app automatically collects the setup and command that resulted in that problem and packages it up into a JSON test that can be run in either of these environments. 

I would like a menu command in JVE such that if something anomalous happens, the user can run the command and the aforementioned test packet will be created even though, as far as JVE can tell, nothing went wrong. That way, we can take the user's configuration and reproduce it and look at what the user is concerned about. 

I want to make this now such that I can employ it in developing JVE and constructing even more regression tests, as regression tests are even more important than the implementation. Because if the implementation were to go away, we could essentially recreate it using the regression tests for test-driven development. 

I assume that this will require a puppeteer style test environment in addition to the mocked and stubbed environment that we have right now. 
