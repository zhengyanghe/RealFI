pin_tool
first modify the Makefile and Makefile.rule

using make to generate

obj-intel64

│   ├── bit_flippers.o

│   └── bit_flippers.so

then using the command

```bash
setarch $(uname -m) -R pin -t fault_injector/obj-intel64/bit_flippers.so -addr 0x555555559ea4 -occ 1 -- /path/to/your/application