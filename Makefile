.PHONY: test

test:
	bash scripts/tests/test_common_args.sh
	bash scripts/tests/test_build_microservices.sh
