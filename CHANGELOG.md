# Changelog

All notable changes to this project will be documented in this file. See [commit-and-tag-version](https://github.com/absolute-version/commit-and-tag-version) for commit guidelines.

## 0.2.2 (2026-11-19)

### Features

* add buildx plugin for Docker ([97a44bc](/github.com/PeterMosmans/opencode-sandbox/commit/97a44bc9af652911a478ec64a1cdcdb0fea6c7a9))
* add docker compose plugin ([2c3507c](/github.com/PeterMosmans/opencode-sandbox/commit/2c3507c128eff0bc36e2af832c1ed139ef7869de))
* add first-run initialization option ([95ac922](/github.com/PeterMosmans/opencode-sandbox/commit/95ac9228e4fb2a4e44c58f4ecc88c78efd9824d4))
* add headers, clean up Makefile ([b672623](/github.com/PeterMosmans/opencode-sandbox/commit/b672623924c6e6e551922770443cf1dc7818db4d))
* add more verbosity for startup issues ([e68bb4d](/github.com/PeterMosmans/opencode-sandbox/commit/e68bb4d35b10cc5146048df3ea5703075be13ba9))
* add server tests ([b1092c0](/github.com/PeterMosmans/opencode-sandbox/commit/b1092c0265434bb9cd9ef8b2c93f997695477174))
* add ssh tools to image ([6e93737](/github.com/PeterMosmans/opencode-sandbox/commit/6e937376a61eb34a3c6da142a3738038e9446bb2))
* add test and initial versions ([7f41245](/github.com/PeterMosmans/opencode-sandbox/commit/7f4124592bbbab2eea77c6a49da1e7c5abce840d))
* add test for codebase-memory-mcp ([c3d223a](/github.com/PeterMosmans/opencode-sandbox/commit/c3d223a3827972b20c0434d4b2c2f72f81825764))
* add test to show provider configuration ([0faf225](/github.com/PeterMosmans/opencode-sandbox/commit/0faf2251483dc6200da850df44bb9904d4417f6f))
* allow dynamic setting of timezone in image ([1a04788](/github.com/PeterMosmans/opencode-sandbox/commit/1a04788ae74953228a183c814a8a2fd02ee8194e))
* allow Playwright MCP to use persistent data ([1ced23e](/github.com/PeterMosmans/opencode-sandbox/commit/1ced23e0127fd9446742152d2466d94f3a49ccf7))
* automatically install extra packages ([c5e044c](/github.com/PeterMosmans/opencode-sandbox/commit/c5e044cef3de12d7fdef58bbe6a1d559da55848b))
* change default Docker detach bindings ([fcd6e2b](/github.com/PeterMosmans/opencode-sandbox/commit/fcd6e2b00f72d4962f0036df9550913e41fc8bbd))
* create temporary Docker build context ([823bf81](/github.com/PeterMosmans/opencode-sandbox/commit/823bf811747011e30b73b79664569c0fa62c8a61))
* display build parameters ([5e9b792](/github.com/PeterMosmans/opencode-sandbox/commit/5e9b792db56b506bdeae2aebd544e809e927f113))
* don't enforce existence of configuration ([52d327b](/github.com/PeterMosmans/opencode-sandbox/commit/52d327b6d3b317aa6f5f94c78658d6d3326abe78))
* enable running from any location ([b66d72c](/github.com/PeterMosmans/opencode-sandbox/commit/b66d72cd44b6eaab99fed374edbb6bee45985bda))
* enhance Makefile's robustness ([4964128](/github.com/PeterMosmans/opencode-sandbox/commit/49641280707327c43061c81f81886e19b172bb1d))
* enhance path, add rsync ([5adb3de](/github.com/PeterMosmans/opencode-sandbox/commit/5adb3dec40f0bf950e1c752002da0e24ed5469bb))
* implement rootless docker-in-docker mode ([919f6df](/github.com/PeterMosmans/opencode-sandbox/commit/919f6df8910c800a26b2715ce27765ddec2beaa0))
* improve screenshot tests ([b22fed6](/github.com/PeterMosmans/opencode-sandbox/commit/b22fed6cc4758e925a848dea05e502352cc782c0))
* improve tests and re-order flow ([8f8d355](/github.com/PeterMosmans/opencode-sandbox/commit/8f8d3553c4a1e4e1259b9ad58881a4e41104fc83))
* improve tests and update scripts ([4df2ca5](/github.com/PeterMosmans/opencode-sandbox/commit/4df2ca5732185c783f4ed4a9dbae59596cd9953b))
* make secure TLS the default (STRICT_TLS) ([f142370](/github.com/PeterMosmans/opencode-sandbox/commit/f142370fc403bc4d4dc262e48c937c54bc182e76))
* minimize docker image size ([2be5972](/github.com/PeterMosmans/opencode-sandbox/commit/2be5972e170a5c1bcd9460f31439e2504cc1b80b))
* pin and check downloaded versions ([d356c22](/github.com/PeterMosmans/opencode-sandbox/commit/d356c224a1236ee82a82652ee6843ac1cab163e8))
* pin Docker base image and remove sudo ([d5c9e39](/github.com/PeterMosmans/opencode-sandbox/commit/d5c9e390096f700f0b7c5d05681e08dbf67feaf8))
* remove Openspec MCP server ([67bf2a1](/github.com/PeterMosmans/opencode-sandbox/commit/67bf2a177d1262d165a914cb93302f4943d8a3ff))
* remove optional mounts from Makefile ([1aa6865](/github.com/PeterMosmans/opencode-sandbox/commit/1aa686530435fb9842bf0d45a5edc56396ea1472))
* rename elevated to insecure, explain threat model ([96bee5f](/github.com/PeterMosmans/opencode-sandbox/commit/96bee5fcb617b6fc1b1b7f6a98c8bfc63d8221fd))
* show versions of installed extra modules ([d6496d6](/github.com/PeterMosmans/opencode-sandbox/commit/d6496d677581ca65681541355dcdef34f98e7fb4))
* store extra installed modules in image ([b64dadf](/github.com/PeterMosmans/opencode-sandbox/commit/b64dadf4f6e1840b475d48529049e8f242ded6d0))
* support installing extra packages ([d6cdeb7](/github.com/PeterMosmans/opencode-sandbox/commit/d6cdeb76f70a4cc49f006c0c0fcfc7fee91ecf64))
* unified version audit and bump tool ([78975af](/github.com/PeterMosmans/opencode-sandbox/commit/78975af3a97cd1b53607e1c6ccc35abc72ff7141))
* update packages ([56e3823](/github.com/PeterMosmans/opencode-sandbox/commit/56e3823a06df63cf3a4e48bd9e9516ad93259cd7))
* update packages ([0d7cadb](/github.com/PeterMosmans/opencode-sandbox/commit/0d7cadb982bf0b8e370d8da19483c9b398fed16c))
* update packages ([844238b](/github.com/PeterMosmans/opencode-sandbox/commit/844238b89b166ec5c0e96014f01708eb884fbe19))
* update packages ([8c8ad1e](/github.com/PeterMosmans/opencode-sandbox/commit/8c8ad1e1600badddaa7a02a8e44fc61f9f2faec2))
* update packages ([9074ae7](/github.com/PeterMosmans/opencode-sandbox/commit/9074ae748661fb89428b1f8a99adb2dd610cc557))
* update packages ([54003aa](/github.com/PeterMosmans/opencode-sandbox/commit/54003aa34315ae6ad20ea99e5145587456e151d7))
* update packages ([28c9845](/github.com/PeterMosmans/opencode-sandbox/commit/28c9845a3bb6c52c8bad382cdba2e96db31b8c5e))
* update packages ([b99b284](/github.com/PeterMosmans/opencode-sandbox/commit/b99b28416de084a4122e205027ed228eb76fd10b))
* update packages ([acbc5d1](/github.com/PeterMosmans/opencode-sandbox/commit/acbc5d1354b0e8b4371cb53f7b1c42d9d7befe8a))
* update packages / remove beads ([c02acd5](/github.com/PeterMosmans/opencode-sandbox/commit/c02acd513144702129060021b1607703f53ebddf))
* update versions ([1c24ab5](/github.com/PeterMosmans/opencode-sandbox/commit/1c24ab5946116fff601719e4caa67bb23c5a4147))
* use defaults when no .env exists ([ba38fd3](/github.com/PeterMosmans/opencode-sandbox/commit/ba38fd32941e4355743c81e546a61528c086bcf1))

### Bug Fixes

* allow "non-existing" context directories ([1d14da6](/github.com/PeterMosmans/opencode-sandbox/commit/1d14da61ef6bb3399937c006b15baf8e2ef0d9b4))
* don't error out without extra directory ([bf77f6f](/github.com/PeterMosmans/opencode-sandbox/commit/bf77f6fc750552b44cbf209ddf42523382711f25))
* dynamically read docker group ([6184989](/github.com/PeterMosmans/opencode-sandbox/commit/6184989a611cdf4544eae20dfb8bffd14181a565))
* make auth mount optional ([49fba7f](/github.com/PeterMosmans/opencode-sandbox/commit/49fba7fa7639bd1f661cd46ecaf018e15e69adcb))
* remove trailing colon ([4133086](/github.com/PeterMosmans/opencode-sandbox/commit/41330864dbcd69241fd67b9afe56d99672cd5bbe))
* remove unused targets ([273febc](/github.com/PeterMosmans/opencode-sandbox/commit/273febc222b1a24f0a977867a2cbffb32b2390ed))
* robustly check hashes and warn against file corruption ([2b862fa](/github.com/PeterMosmans/opencode-sandbox/commit/2b862fad311c512ebb8617bcfc1a7912853391d3))
* show help first, improve error checking ([680f090](/github.com/PeterMosmans/opencode-sandbox/commit/680f0901cb992bac08a848b7e91cec9db1ba4d0f))
* use correct absolute path for Playwright ([581d369](/github.com/PeterMosmans/opencode-sandbox/commit/581d369e567864eb5dedd5209975b4cfbddee3fc))
* use ephemeral parameters during testing ([8353753](/github.com/PeterMosmans/opencode-sandbox/commit/83537534cba4c49eb958dedcf9ca96aa91693d75))

## [0.2.0](https://github.com/PeterMosmans/opencode-sandbox/compare/0.1.1...0.2.0) (2026-08-27)


### Features

* add buildx plugin for Docker ([97a44bc](https://github.com/PeterMosmans/opencode-sandbox/commit/97a44bc9af652911a478ec64a1cdcdb0fea6c7a9))
* add first-run initialization option ([95ac922](https://github.com/PeterMosmans/opencode-sandbox/commit/95ac9228e4fb2a4e44c58f4ecc88c78efd9824d4))
* add headers, clean up Makefile ([b672623](https://github.com/PeterMosmans/opencode-sandbox/commit/b672623924c6e6e551922770443cf1dc7818db4d))
* add ssh tools to image ([6e93737](https://github.com/PeterMosmans/opencode-sandbox/commit/6e937376a61eb34a3c6da142a3738038e9446bb2))
* change default Docker detach bindings ([fcd6e2b](https://github.com/PeterMosmans/opencode-sandbox/commit/fcd6e2b00f72d4962f0036df9550913e41fc8bbd))
* create temporary Docker build context ([823bf81](https://github.com/PeterMosmans/opencode-sandbox/commit/823bf811747011e30b73b79664569c0fa62c8a61))
* implement rootless docker-in-docker mode ([919f6df](https://github.com/PeterMosmans/opencode-sandbox/commit/919f6df8910c800a26b2715ce27765ddec2beaa0))
* improve tests and re-order flow ([8f8d355](https://github.com/PeterMosmans/opencode-sandbox/commit/8f8d3553c4a1e4e1259b9ad58881a4e41104fc83))
* make secure TLS the default (STRICT_TLS) ([f142370](https://github.com/PeterMosmans/opencode-sandbox/commit/f142370fc403bc4d4dc262e48c937c54bc182e76))
* minimize docker image size ([2be5972](https://github.com/PeterMosmans/opencode-sandbox/commit/2be5972e170a5c1bcd9460f31439e2504cc1b80b))
* pin and check downloaded versions ([d356c22](https://github.com/PeterMosmans/opencode-sandbox/commit/d356c224a1236ee82a82652ee6843ac1cab163e8))
* pin Docker base image and remove sudo ([d5c9e39](https://github.com/PeterMosmans/opencode-sandbox/commit/d5c9e390096f700f0b7c5d05681e08dbf67feaf8))
* remove Openspec MCP server ([67bf2a1](https://github.com/PeterMosmans/opencode-sandbox/commit/67bf2a177d1262d165a914cb93302f4943d8a3ff))
* rename elevated to insecure, explain threat model ([96bee5f](https://github.com/PeterMosmans/opencode-sandbox/commit/96bee5fcb617b6fc1b1b7f6a98c8bfc63d8221fd))
* update packages ([54003aa](https://github.com/PeterMosmans/opencode-sandbox/commit/54003aa34315ae6ad20ea99e5145587456e151d7))


### Bug Fixes

* allow "non-existing" context directories ([1d14da6](https://github.com/PeterMosmans/opencode-sandbox/commit/1d14da61ef6bb3399937c006b15baf8e2ef0d9b4))
* robustly check hashes and warn against file corruption ([2b862fa](https://github.com/PeterMosmans/opencode-sandbox/commit/2b862fad311c512ebb8617bcfc1a7912853391d3))
* use ephemeral parameters during testing ([8353753](https://github.com/PeterMosmans/opencode-sandbox/commit/83537534cba4c49eb958dedcf9ca96aa91693d75))

## [0.1.1](https://github.com/PeterMosmans/opencode-sandbox/compare/0.1.0...0.1.1) (2026-08-24)


### Features

* add server tests ([b1092c0](https://github.com/PeterMosmans/opencode-sandbox/commit/b1092c0265434bb9cd9ef8b2c93f997695477174))
* add test to show provider configuration ([0faf225](https://github.com/PeterMosmans/opencode-sandbox/commit/0faf2251483dc6200da850df44bb9904d4417f6f))
* display build parameters ([5e9b792](https://github.com/PeterMosmans/opencode-sandbox/commit/5e9b792db56b506bdeae2aebd544e809e927f113))
* don't enforce existence of configuration ([52d327b](https://github.com/PeterMosmans/opencode-sandbox/commit/52d327b6d3b317aa6f5f94c78658d6d3326abe78))
* improve screenshot tests ([b22fed6](https://github.com/PeterMosmans/opencode-sandbox/commit/b22fed6cc4758e925a848dea05e502352cc782c0))
* improve tests and update scripts ([4df2ca5](https://github.com/PeterMosmans/opencode-sandbox/commit/4df2ca5732185c783f4ed4a9dbae59596cd9953b))
* update packages ([28c9845](https://github.com/PeterMosmans/opencode-sandbox/commit/28c9845a3bb6c52c8bad382cdba2e96db31b8c5e))
* update packages ([b99b284](https://github.com/PeterMosmans/opencode-sandbox/commit/b99b28416de084a4122e205027ed228eb76fd10b))
* update packages ([acbc5d1](https://github.com/PeterMosmans/opencode-sandbox/commit/acbc5d1354b0e8b4371cb53f7b1c42d9d7befe8a))
* use defaults when no .env exists ([ba38fd3](https://github.com/PeterMosmans/opencode-sandbox/commit/ba38fd32941e4355743c81e546a61528c086bcf1))


### Bug Fixes

* dynamically read docker group ([6184989](https://github.com/PeterMosmans/opencode-sandbox/commit/6184989a611cdf4544eae20dfb8bffd14181a565))
* remove trailing colon ([4133086](https://github.com/PeterMosmans/opencode-sandbox/commit/41330864dbcd69241fd67b9afe56d99672cd5bbe))

## 0.1.0 (2026-08-03)


### Features

* add test and initial versions ([7f41245](https://github.com/PeterMosmans/opencode-sandbox/commit/7f4124592bbbab2eea77c6a49da1e7c5abce840d))


### Bug Fixes

* make auth mount optional ([49fba7f](https://github.com/PeterMosmans/opencode-sandbox/commit/49fba7fa7639bd1f661cd46ecaf018e15e69adcb))
* remove unused targets ([273febc](https://github.com/PeterMosmans/opencode-sandbox/commit/273febc222b1a24f0a977867a2cbffb32b2390ed))
