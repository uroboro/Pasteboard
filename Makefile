export TARGET = iphone:clang:6.1
export ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TOOL_NAME = pasteboard
pasteboard_FILES = main.mm
pasteboard_FRAMEWORKS = UIKit MobileCoreServices

include $(THEOS_MAKE_PATH)/tool.mk

EXECUTOR = $(or $(THEOS_OBJ_DIR),./)/$(firstword $(TOOL_NAME))
DESCR = @printf "\e[36m>\e[m TESTING \"\e[32m$@\e[m\"\n\e[36;1m>\e[m "
LI = @var="
LO = "; printf "\e[33;1m%s\e[m\n" "$$var"; $$var

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
	echo test | $(EXECUTOR) | grep . || true
	@echo

test_pipe: test_pin test_pout test_pinout

test_fin: all
	$(DESCR)
	$(EXECUTOR) < file.txt
	$(LI)cat file.txt$(LO)
	@echo

test_fout: all
	$(DESCR)
	$(EXECUTOR) > file2.txt
	$(LI)cat file2.txt$(LO)
	@echo

test_finout: all
	$(DESCR)
	$(EXECUTOR) < file.txt > file2.txt
	$(LI)cat file2.txt$(LO)
	@echo


test_file: test_fin test_fout test_finout

test_all: test test_pipe test_file
