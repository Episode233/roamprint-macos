Legacy protocol primitives
==========================

Twofish: Niels Ferguson, portable C implementation version 0.3, copyright
2002. Source and full perpetual license are preserved in vendor/twofish.c.
Retrieved from keybase/python-twofish commit
c4b9cdbb15727c89c14a7d808ec1a59e84da7149, twofish-0.3/twofish.{c,h}.
https://github.com/keybase/python-twofish/tree/c4b9cdbb15727c89c14a7d808ec1a59e84da7149/twofish-0.3
Local change: the fatal self-test handler aborts instead of hanging indefinitely.
The header uses exact-width uint8_t and uint32_t types; default portable byte
loads avoid alignment and aliasing assumptions on ARM64. Initialisation is
guarded by pthread_once; per-request expanded keys are cleared after use.

MD5: Brad Conte, public-domain crypto-algorithms, commit
cfbde48414baacf51fc7c74f275190881f037d32, md5.{c,h}.
https://github.com/B-Con/crypto-algorithms/tree/cfbde48414baacf51fc7c74f275190881f037d32
The upstream public-domain statement and disclaimer are retained in
vendor/md5-LICENSE.txt. Local change: input bytes are converted to the unsigned
32-bit WORD before shifting, to avoid signed integer promotion overflow.

These primitives serve compatibility with the existing enterprise service.
They are not a general-purpose password-storage or encryption facility.
No downloaded Intel executables are used at runtime.
