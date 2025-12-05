# Top-level makefile for fault_injector pintool

# 如果环境里没设 PIN_ROOT，就用默认路径
PIN_ROOT ?= /opt/pin

# 保险起见，让优化等级是 O0，避免编译器把指令折腾没了
OPT = -O0
TOOL_CXXFLAGS += -O0 -fno-inline -fno-inline-functions

# Pin 官方的配置
ifdef PIN_ROOT
CONFIG_ROOT := $(PIN_ROOT)/source/tools/Config
else
$(error PIN_ROOT is not set!)
endif

# 1) Pin 的通用配置
include $(CONFIG_ROOT)/makefile.config

# 2) 本目录自己的规则（定义 TOOL_ROOTS 等）
include makefile.rules

# 3) Pin 默认的构建规则
include $(TOOLS_ROOT)/Config/makefile.default.rules
