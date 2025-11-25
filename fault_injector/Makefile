PIN_ROOT ?= /opt/pin
OPT = -O0
TOOL_CXXFLAGS += -O0 -fno-inline -fno-inline-functions
ifdef PIN_ROOT
CONFIG_ROOT := $(PIN_ROOT)/source/tools/Config
else
$(error PIN_ROOT is not set!)
endif
include $(CONFIG_ROOT)/makefile.config
include makefile.rules
include $(TOOLS_ROOT)/Config/makefile.default.rules
