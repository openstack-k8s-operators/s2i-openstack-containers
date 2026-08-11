SHELL := bash

GENERATED_USERS := containers/base/scripts/zz_generated_users.txt

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Users / UID-GID Registry

.PHONY: generate-service-uids
generate-service-uids: ## Regenerate containers/base/scripts/zz_generated_users.txt from Go constants in users/registry.go.
	cd users && go run ./cmd/gen-users ../$(GENERATED_USERS)

.PHONY: verify-service-uids
verify-service-uids: ## Verify zz_generated_users.txt is up-to-date (fails if regeneration produces a diff).
	@cp $(GENERATED_USERS) $(GENERATED_USERS).bak
	@$(MAKE) generate-service-uids || \
		(mv $(GENERATED_USERS).bak $(GENERATED_USERS); exit 1)
	@diff $(GENERATED_USERS).bak $(GENERATED_USERS) || \
		(echo ""; echo "ERROR: $(GENERATED_USERS) is out of date. Run 'make generate-service-uids' and commit the result."; \
		 mv $(GENERATED_USERS).bak $(GENERATED_USERS); exit 1)
	@rm -f $(GENERATED_USERS).bak
	@echo "$(GENERATED_USERS) is up-to-date."

##@ Testing

.PHONY: test-users
test-users: ## Run users package tests.
	cd users && go test -v ./...

.PHONY: test
test: test-users ## Run all tests.
