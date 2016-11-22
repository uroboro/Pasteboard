export TARGET = iphone:clang:6.1
export ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TOOL_NAME = pasteboard
pasteboard_FILES = main.mm
pasteboard_FRAMEWORKS = UIKit MobileCoreServices

include $(THEOS_MAKE_PATH)/tool.mk

EXECUTOR = $(or $(THEOS_OBJ_DIR),./)/$(firstword $(TOOL_NAME))

FILE_IN = file.txt
FILE_OUT = file2.txt
IMAGE_IN = Icon.png
IMAGE_OUT = Icon2.png

DESCR = @printf "\e[36m>\e[m TESTING \"\e[32m$@\e[m\"\n\e[36;1m>\e[m "
LI = @var="
LO = "; printf "\e[33;1m%s\e[m\n" "$$var"; $$var

after-all::
	@rm -rf obj

clean::
	@rm -rf $(FILE_OUT) $(IMAGE_OUT)

test: all
	$(DESCR)
	$(EXECUTOR) $(ARGS)
	@echo

test_pin: all
	$(DESCR)
	echo test | $(EXECUTOR)
	@echo

test_pout: all
	$(DESCR)
	$(EXECUTOR) | grep .
	@echo

test_pinout: all
	$(DESCR)
	echo test | $(EXECUTOR) | grep .
	@echo

test_pipe: test_pin test_pout test_pinout

test_fin: all
	$(DESCR)
	$(EXECUTOR) < $(FILE_IN)
	$(LI)cat $(FILE_IN)$(LO)
	@echo

test_fout: all
	$(DESCR)
	$(EXECUTOR) > $(FILE_OUT)
	$(LI)cat $(FILE_OUT)$(LO)
	@echo

test_finout: all
	$(DESCR)
	$(EXECUTOR) < $(FILE_IN) > $(FILE_OUT)
	$(LI)cat $(FILE_OUT)$(LO)
	@echo

test_file: test_fin test_fout test_finout

test_imgin: all
	$(DESCR)
	$(EXECUTOR) < $(IMAGE_IN)
	@echo

test_imgout: all
	$(DESCR)
	$(EXECUTOR) > $(IMAGE_OUT)
	@echo

test_imginout: all
	$(DESCR)
	$(EXECUTOR) < $(IMAGE_IN) > $(IMAGE_OUT)
	@echo

test_image: test_imgin test_imgout test_imginout

test_all: test test_pipe test_file test_image
	@echo All tests passed
