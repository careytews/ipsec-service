
VERSION=$(shell git describe | sed 's/^v//')

CONTAINER=gcr.io/trust-networks/ipsec-svc:${VERSION}

all: dhcp-server
	docker build ${BUILD_ARGS} -t ${CONTAINER} -f Dockerfile  .

dhcp-server: dhcp-server.go godeps
	GOPATH=$$(pwd)/go go build dhcp-server.go

godeps: go go/.dhcp

go:
	mkdir go

go/.dhcp:
	GOPATH=$$(pwd)/go go get github.com/krolaw/dhcp4
	touch $@

run:
	docker run -i -t --cap-add NET_ADMIN ${CONTAINER}

push:
	gcloud docker -- push ${CONTAINER}

BRANCH=master
PREFIX=resources/$(shell basename $(shell git remote get-url origin))
FILE=${PREFIX}/ksonnet/version.jsonnet
REPO=$(shell git remote get-url origin)

tools: phony
	if [ ! -d tools ]; then \
		git clone git@github.com:trustnetworks/cd-tools tools; \
	fi; \
	(cd tools; git pull)

phony:

bump-version: tools
	tools/bump-version

update-cluster-config: tools
	tools/update-cluster-config ${BRANCH} ${PREFIX} ${FILE} ${VERSION} \
	    ${REPO}

