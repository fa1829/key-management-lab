# key-management-lab -- run `make help`
SHELL := /bin/bash
ENV   := source config/lab.env &&
PY    := .venv/bin/python
PYK   := OPENSSL_CONF=/dev/null .venv-kmip/bin/python

.PHONY: help install doctor hsm envelope pki revoke kmip-start kmip-demo kmip-stop kmip-log exporter metrics renew-dry renew monitoring-up monitoring-down status clean demo reset

help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-16s %s\n", $$1, $$2}'

install: ## apt packages + Python venvs (run once, ~5 min)
	./scripts/00_install.sh

doctor: ## pre-flight check: what is installed, what is missing
	./scripts/00_doctor.sh

hsm: ## 01: create HSM tokens, generate keys inside them, sign and verify
	./scripts/01_hsm_init.sh && ./scripts/01_hsm_keys.sh

envelope: ## 01: envelope encryption via PKCS#11 + proof keys cannot be read out
	$(ENV) $(PY) python/pkcs11_envelope.py

pki: ## 02: two-tier PKI with CA keys in the HSM, issue certificates
	./scripts/02_pki_build.sh

revoke: ## 02: revoke a certificate and publish an HSM-signed CRL
	./scripts/02_pki_revoke.sh

kmip-start: ## 03: start the KMIP server (mutual TLS with lab certificates)
	./scripts/03_kmip_server.sh start

kmip-demo: ## 03: full key lifecycle over KMIP
	$(ENV) $(PYK) python/kmip_lifecycle.py

kmip-stop: ## 03: stop the KMIP server
	./scripts/03_kmip_server.sh stop

kmip-log: ## 03: follow the KMIP server log (Ctrl+C to stop)
	tail -f run/kmip/server.log

exporter: ## 04: serve Prometheus metrics on :9105 (Ctrl+C to stop)
	$(ENV) $(PY) python/crypto_exporter.py

metrics: ## 04: print the metrics once
	$(ENV) $(PY) python/crypto_exporter.py --once | grep -v '^#'

renew-dry: ## 04: show which certificates would be renewed
	$(ENV) $(PY) python/renew_expiring.py --dry-run

renew: ## 04: renew certificates expiring within 15 days (new keys)
	$(ENV) $(PY) python/renew_expiring.py

monitoring-up: ## 04: start Prometheus (:9090) and Grafana (:3000) in Docker
	cd monitoring && docker compose up -d
	@echo 'Grafana: http://localhost:3000 (admin / labadmin)   Prometheus: http://localhost:9090'

monitoring-down: ## 04: stop Prometheus and Grafana
	cd monitoring && docker compose down

status: ## show what is running and what has been generated
	@./scripts/03_kmip_server.sh status | sed 's/^/KMIP server: /'
	@ls run/pki/certs 2>/dev/null | sed 's/^/certificate: /' || echo 'no PKI yet: make pki'
	@(docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | grep kml) || echo 'monitoring containers: not running'

clean: ## delete all generated state (tokens, PKI, KMIP database)
	-./scripts/03_kmip_server.sh stop
	rm -rf run

demo: hsm envelope pki revoke kmip-start kmip-demo renew-dry metrics ## run modules 01-04 end to end

reset: clean demo ## wipe everything and run the demo again from scratch
