<!-- Pull requests go into `main`. One feature (or one fix) per pull request. -->

## What this changes

<!-- In plain words: what can a person do now that they could not do before? Or what is fixed? -->

## Why

<!-- Link the issue if there is one: "Closes #123". -->

## How I checked it

<!-- What you ran and what you tried by hand. Add a screenshot or short recording for anything you can see. -->

- [ ] `pnpm check` passes (lint, build and tests).
- [ ] New behaviour has tests that go through the module's interface, using the in-memory fakes.
- [ ] Nothing new leaves the device: no analytics, no new network calls except to the AI server the user set.
- [ ] The API key is not in any file, log, error message or test.
- [ ] Text people see is plain English. Screens work in light and dark mode and have VoiceOver labels.
- [ ] No code, images, sounds or wording copied from another product.
