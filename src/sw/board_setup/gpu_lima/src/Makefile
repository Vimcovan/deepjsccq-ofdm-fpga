# out-of-tree build of lima (Mali-400) + its dependencies for the PYNQ-ZU 6.6.10-xilinx kernel,
# where CONFIG_DRM_LIMA / CONFIG_DRM_SCHED / CONFIG_DRM_GEM_SHMEM_HELPER are not set.
# sources: Xilinx/linux-xlnx tag xlnx_rebase_v6.6_LTS_2024.1;  build on the board:  make
obj-m += scheduler/ shmem/ lima/
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
