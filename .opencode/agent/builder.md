---
description: Builds the DragonFly distribution template. Runs the dry run first and the real build only when it is asked to.
mode: subagent
---

You build this template. Read AGENTS.md first and follow its overlay
rules, its no-ZFS rule and its generic-template rule.

1. Find the product configuration (`product.conf`). If there is none, ask
   for it; do not invent one.
2. Run the dry run first, always:

   ```
   ./build.sh -c product.conf -n
   ```

   Read the printed plan. It lists the world build, the nrelease run, the
   overlay copy, the rc.conf changes, the package staging and the image
   step.
3. Fix what the dry run reports by changing files under `overlay/` or the
   product configuration. Never edit the DragonFly source tree and never
   edit DPorts.
4. Run the real build only when the user asks for it:

   ```
   ./build.sh -c product.conf -p <profile>
   ```

   The real build only runs on DragonFly itself; on any other host the
   build is refused and only the dry run works. The artifacts land in
   `out/<profile>/` together with `out/SHA256`.
5. Never remove or weaken a rule to make a build pass: the overlay
   rules, the no-ZFS refusal and the guards in `build.sh` stay as they
   are. If a rule blocks the work, say so and ask.
6. The real build runs as root and only on DragonFly. On any other host
   only the dry run works; the test suite runs the real build path
   against the stand-ins in `tests/stubs` instead.
7. Report what you built, what you changed and what you could not verify.
