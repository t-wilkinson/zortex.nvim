LAMBDA_PROCESSOR_NAME := zortex-manifest-processor
LAMBDA_SENDER_NAME    := zortex-notification-sender

PROCESSOR_ZIP := manifest_processor.zip
SENDER_ZIP    := notification_sender.zip
PROCESSOR_SRC_FILES := $(wildcard manifest_processor/*.py)

VENDOR_DIR := manifest_processor/vendor

.PHONY: all deploy deploy-processor deploy-sender vendor clean

all: $(PROCESSOR_ZIP) $(SENDER_ZIP)

$(VENDOR_DIR): requirements.txt
	@echo "--> Installing dependencies from requirements.txt into $(VENDOR_DIR)"
	@uv pip install --system --quiet --target $(VENDOR_DIR) -r requirements.txt

vendor: $(VENDOR_DIR)


$(PROCESSOR_ZIP): requirements.txt $(PROCESSOR_SRC_FILES)
	@echo "--> Creating processor package: $@"
	@cd manifest_processor && zip -rq ../$(PROCESSOR_ZIP) *.py
	@cd $(VENDOR_DIR) && zip -g -r -q ../../$(PROCESSOR_ZIP) .

$(SENDER_ZIP): notification_sender.py
	@echo "--> Creating sender package: $@"
	@zip -q $(SENDER_ZIP) notification_sender.py

zip: manifest_processor notification_sender requirements.txt

freeze: $(PROCESSOR_SRC_FILES)
	PYTHON_PATH=./manifest_processor/vendor uv pip freeze > requirements.txt

deploy: deploy-processor

deploy-processor: $(PROCESSOR_ZIP)
	@echo "--> Deploying $(PROCESSOR_ZIP) to Lambda function: $(LAMBDA_PROCESSOR_NAME)"
	@aws lambda update-function-code --function-name $(LAMBDA_PROCESSOR_NAME) --zip-file fileb://$(PROCESSOR_ZIP)
	@echo "--> Deployment successful!"

deploy-sender: $(SENDER_ZIP)
	@echo "--> Deploying $(SENDER_ZIP) to Lambda function: $(LAMBDA_SENDER_NAME)"
	@aws lambda update-function-code --function-name $(LAMBDA_SENDER_NAME) --zip-file fileb://$(SENDER_ZIP)
	@echo "--> Deployment successful!"

clean:
	@echo "--> Cleaning up generated files"
	@rm -f $(PROCESSOR_ZIP) $(SENDER_ZIP)
