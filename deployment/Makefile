zip := manifest_processor.zip
lambda := zortex-manifest-processor

HANDLER_PACKAGES = $(wildcard manifest_processor_packages/*)

$(zip): handler.py notification_sender.py requirements.txt
	uv pip install --quiet --target build -r requirements.txt
	cd manifest_processor_packages && zip -rq ../$@ .
	zip -g $@ handler.py notification_sender.py

.PHONY: deploy
deploy: $(zip)
	aws lambda update-function-code --function-name $(lambda) --zip-file fileb://$(zip)

freeze: $(HANDLER_PACKAGES)
	PYTHON_PATH=./manifest_processor_packages uv pip freeze > requirements.txt

