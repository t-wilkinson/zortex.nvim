LAMBDA_PROCESSOR_NAME := zortex-manifest-processor
LAMBDA_SENDER_NAME    := zortex-notification-sender

PROCESSOR_ZIP := manifest_processor.zip
SENDER_ZIP    := notification_sender.zip
PROCESSOR_SRC_FILES := $(wildcard manifest_processor/*.py)

PROCESSOR_REQUIREMENTS := manifest_processor/requirements.txt
VENDOR_DIR := manifest_processor/vendor

.PHONY: all vendor freeze deploy deploy-processor deploy-sender clean

# ==============================================================================
# ALL
# ==============================================================================
all: $(PROCESSOR_ZIP) $(SENDER_ZIP)

# ==============================================================================
# ZIP
# ==============================================================================
$(PROCESSOR_ZIP): $(PROCESSOR_SRC_FILES) vendor
	@echo "--> Creating processor package: $@"
	@cd manifest_processor && zip -rq ../$(PROCESSOR_ZIP) *.py
	@cd $(VENDOR_DIR) && zip -g -r -q ../../$(PROCESSOR_ZIP) .

$(SENDER_ZIP): notification_sender.py
	@echo "--> Creating sender package: $@"
	@zip -q $(SENDER_ZIP) notification_sender.py

# ==============================================================================
# VENDOR
# ==============================================================================
vendor: $(VENDOR_DIR)

$(VENDOR_DIR): $(PROCESSOR_REQUIREMENTS)
	@echo "--> Installing dependencies from requirements.txt into $(VENDOR_DIR)"
	@uv pip install --system --quiet --target $(VENDOR_DIR) -r $(PROCESSOR_REQUIREMENTS)

# ==============================================================================
# FREEZE
# ==============================================================================
freeze: $(PROCESSOR_SRC_FILES)
	@echo "--> Freezing $(VENDOR_DIR) into requirements.txt"
	@PYTHON_PATH=$(VENDOR_DIR) uv pip freeze > $(PROCESSOR_REQUIREMENTS)

# ==============================================================================
# DEPLOY
# ==============================================================================
deploy: deploy-processor

deploy-processor: $(PROCESSOR_ZIP)
	@echo "--> Deploying $(PROCESSOR_ZIP) to Lambda function: $(LAMBDA_PROCESSOR_NAME)"
	@aws lambda update-function-code --function-name $(LAMBDA_PROCESSOR_NAME) --zip-file fileb://$(PROCESSOR_ZIP)
	@echo "--> Deployment successful!"

deploy-sender: $(SENDER_ZIP)
	@echo "--> Deploying $(SENDER_ZIP) to Lambda function: $(LAMBDA_SENDER_NAME)"
	@aws lambda update-function-code --function-name $(LAMBDA_SENDER_NAME) --zip-file fileb://$(SENDER_ZIP)
	@echo "--> Deployment successful!"

# ==============================================================================
# CLEAN
# ==============================================================================
clean:
	@echo "--> Cleaning up generated files"
	@rm -f $(PROCESSOR_ZIP) $(SENDER_ZIP)
