obj-m := hp-wmi.o

KVER ?= $(shell uname -r)
KDIR ?= /usr/lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) LLVM=1 modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a $(KVER)
