# Source gate for this repository: fast, offline, and it changes no source file.
# It mirrors .github/workflows/tests.yml, so a commit that passes here passes CI.
#
#   make check
#
# The Python tests need the packages in games/totk/requirements.txt; install them once
# (the CI does the same with pip) and this stays offline.

# CI pins Python 3.14 (compression.zstd), and tests/test_mod_manifest.py skips its zstd cases without it: a gate on an
# older interpreter can pass while CI fails, so the default is the version CI runs. Override with PYTHON=... .
PYTHON ?= python3.14
CC ?= cc

.PHONY: check

check:
	$(PYTHON) -m unittest discover -s tests -q
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT; \
	 $(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all \
	   tests/test_romfs_paths.c -o "$$tmp/test-romfs-paths" && "$$tmp/test-romfs-paths" && \
	 $(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all \
	   tests/test_controller_map.c -o "$$tmp/test-controller-map" && "$$tmp/test-controller-map"
