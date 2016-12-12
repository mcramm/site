build:
	cd dev/blog && lein cljsbuild once om-intro
	cd dev/blog && lein cljsbuild once lein-templates
	hugo

serve.drafts:
	hugo --watch --buildDrafts serve

serve:
	hugo --watch server

.PHONY: build serve serve.drafts
