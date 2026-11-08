# Security Policy

--- 

## Preamble and security model

**Inkscape is an end-user offline desktop application.**

Any use of it in a networked context (automatically on a server, for instance) should be carefully sandboxed with input validation, and the security of that sandbox is up to the person running it.

Inkscape as an SVG editor can interact with the network, for instance when opening SVG files that link to network files. This allows for privacy leaks similar to pixel tracking, like when opening an HTML file (we have never seen it in the wild in SVG files, but it is doable).
While we allow people to write it in their files, we do not implement general (ECMAScript) abilities of SVG, and have no js engine (so, no arbitrary code should be run when one opens a file).

Extensions are arbitrary code (usually Python) voluntarily ran by the user, and can do anything. We are careful about the extensions that are bundled with Inkscape, but we allow anyone to install any extension, including malicious ones.

Choosing to upload an SVG file that contains data is a user choice which Inkscape will not do by itself (by default. One can create an extension that uploads your file every minute to a nextcloud).

We have no telemetry and no automatic upgrade check.

We usually upgrade dependencies versions with new releases, every few months.

--- 

We will try to reasonably accomodate suggestions that go beyond the scope outlined above, with the means at our disposal (e.g. if libxml has a critical vulnerability that is triggered when opening SVG files, we will release new installers).

Anything explicitely against this scope will be considered a serious security issue (e.g. a SVG file that uploads arbitrary local files when opened, or that runs arbitrary code somehow)

## How to report a vulnerability

If you think you have found a vulnerability, please report it as a private issue in Gitlab, with the following information:
 - How you found it
 - The type of issue
 - What it allows you to do
 - How to trigger it (ideally a PoC)

Thanks for your help!
