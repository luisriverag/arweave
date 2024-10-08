# Based on c_src.mk from erlang.mk by Loic Hoguin <essen@ninenines.eu>

CURDIR := $(shell pwd)
BASEDIR := $(abspath $(CURDIR)/..)

PROJECT ?= $(notdir $(BASEDIR))
PROJECT := $(strip $(PROJECT))

ifeq ($(MODE), debug)
	CFLAGS ?= -O0 -g
	CXXFLAGS ?= -O0 -g
else
	CFLAGS ?= -O3
	CXXFLAGS ?= -O3
endif

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~ts/erts-~ts/include/", [code:root_dir(), erlang:system_info(version)]).' -s init stop)
ERL_INTERFACE_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~ts", [code:lib_dir(erl_interface, include)]).' -s init stop)
ERL_INTERFACE_LIB_DIR ?= $(shell erl -noshell -eval 'io:format("~ts", [code:lib_dir(erl_interface, lib)]).' -s init stop)

# System type and C compiler/flags.

UNAME_SYS := $(shell uname -s)
ifeq ($(UNAME_SYS), Darwin)
	OSX_CPU_ARCH ?= x86_64
	# nix systems may not have sysctl where uname -m will return the correct arch
	SYSCTL_EXISTS := $(shell which sysctl 2>/dev/null)
	ifdef SYSCTL_EXISTS
		ifneq ($(shell sysctl -n machdep.cpu.brand_string | egrep "M(1|2)"),)
	  	OSX_CPU_ARCH = arm64
		endif
  	else
		ifneq ($(shell uname -m | egrep "arm64"),)
	  	OSX_CPU_ARCH = arm64
			endif
	endif
	CC ?= cc
	CFLAGS += -std=c99 -arch $(OSX_CPU_ARCH) -finline-functions -Wall -Wmissing-prototypes
	CXXFLAGS += -arch $(OSX_CPU_ARCH) -finline-functions -Wall
	LDFLAGS ?= -arch $(OSX_CPU_ARCH)
	LDFLAGS += -undefined suppress
else ifeq ($(UNAME_SYS), FreeBSD)
	CC ?= cc
	CFLAGS += -std=c99 -finline-functions -Wall -Wmissing-prototypes
	CXXFLAGS += -finline-functions -Wall
else ifeq ($(UNAME_SYS), Linux)
	CC ?= gcc
	CFLAGS += -std=c99 -finline-functions -Wall -Wmissing-prototypes
	CXXFLAGS += -finline-functions -Wall
endif

ifneq (, $(shell which pkg-config))
	CFLAGS += `pkg-config --cflags openssl`
	CXXFLAGS += `pkg-config --cflags openssl`
	LDFLAGS += `pkg-config --libs openssl`
endif

C_SRC_DIR = $(CURDIR)

CFLAGS += -fPIC -I $(ERTS_INCLUDE_DIR) -I $(ERL_INTERFACE_INCLUDE_DIR) -I /usr/local/include -I ../lib/RandomX/src -I $(C_SRC_DIR)
CXXFLAGS += -fPIC -I $(ERTS_INCLUDE_DIR) -I $(ERL_INTERFACE_INCLUDE_DIR) -I ../lib/RandomX/src -std=c++11
LDLIBS += -L $(ERL_INTERFACE_LIB_DIR) -L /usr/local/lib -lei -lssl -lcrypto 


RX512_OUTPUT ?= $(CURDIR)/../priv/rx512_arweave.so
RX4096_OUTPUT ?= $(CURDIR)/../priv/rx4096_arweave.so
VDF_OUTPUT ?= $(CURDIR)/../priv/vdf_arweave.so

COMMON_RANDOMX_SOURCES = $(wildcard $(C_SRC_DIR)/randomx/*.c $(C_SRC_DIR)/randomx/*.cpp)
RX512_SOURCES = $(COMMON_RANDOMX_SOURCES) $(wildcard $(C_SRC_DIR)/*.c $(C_SRC_DIR)/randomx/rx512/*.c)
RX4096_SOURCES = $(COMMON_RANDOMX_SOURCES) $(wildcard $(C_SRC_DIR)/*.c $(C_SRC_DIR)/randomx/rx4096/*.c)
VDF_SOURCES = $(wildcard $(C_SRC_DIR)/*.c $(C_SRC_DIR)/vdf/*.c $(C_SRC_DIR)/vdf/*.cpp)

RX512_OBJECTS = $(addsuffix .o, $(basename $(RX512_SOURCES)))
RX4096_OBJECTS = $(addsuffix .o, $(basename $(RX4096_SOURCES)))
VDF_OBJECTS = $(addsuffix .o, $(basename $(VDF_SOURCES)))


# Verbosity.

c_verbose_0 = @echo " C     " $(?F);
c_verbose = $(c_verbose_$(V))

cpp_verbose_0 = @echo " CPP   " $(?F);
cpp_verbose = $(cpp_verbose_$(V))

link_verbose_0 = @echo " LD    " $(@F);
link_verbose = $(link_verbose_$(V))

COMPILE_C = $(c_verbose) $(CC) $(CFLAGS) $(CPPFLAGS) -c
COMPILE_CPP = $(cpp_verbose) $(CXX) $(CXXFLAGS) $(CPPFLAGS) -c

$(RX512_OUTPUT): $(RX512_OBJECTS)
	@mkdir -p $(BASEDIR)/priv/
	$(link_verbose) $(CXX) $(RX512_OBJECTS) $(LDFLAGS) $(LDLIBS) ../lib/RandomX/build512/librandomx512.a -shared -o $(RX512_OUTPUT)

$(RX4096_OUTPUT): $(RX4096_OBJECTS)
	@mkdir -p $(BASEDIR)/priv/
	$(link_verbose) $(CXX) $(RX4096_OBJECTS) $(LDFLAGS) $(LDLIBS) ../lib/RandomX/build4096/librandomx4096.a -shared -o $(RX4096_OUTPUT)

$(VDF_OUTPUT): $(VDF_OBJECTS)
	@mkdir -p $(BASEDIR)/priv/
	$(link_verbose) $(CXX) $(VDF_OBJECTS) $(LDFLAGS) $(LDLIBS) -shared -o $(VDF_OUTPUT)

%.o: %.c
	$(COMPILE_C) $(OUTPUT_OPTION) $<

%.o: %.cc
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

%.o: %.C
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

%.o: %.cpp
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

all: $(RX512_OUTPUT) $(RX4096_OUTPUT) $(VDF_OUTPUT)

clean:
	@rm -f $(RX512_OUTPUT) $(RX4096_OUTPUT) $(VDF_OUTPUT) $(RX512_OBJECTS) $(RX4096_OBJECTS) $(VDF_OBJECTS)





