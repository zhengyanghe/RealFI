# pin_tool

first modify the Makefile and Makefile.rule

using `make` to generate 

obj-intel64

│   ├── pc_profiler.o

│   └── pc_profiler.so

then using the command

```bash
pin -t obj-intel64/pc_profiler.so -o output_file.csv -sample_interval number -- /path/to/your/application