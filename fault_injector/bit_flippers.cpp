#include "pin.H"
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <ctime>

// 💡 步骤一：定义你要进行注错的指令地址
// 请将此地址替换为你实际要注错的地址！
// const ADDRINT TARGET_INSTR_ADDR = 0x0000555555555165; // 示例地址
// const ADDRINT TARGET_INSTR_ADDR = 0x0000555555555176;
KNOB<ADDRINT> KnobTargetAddr(KNOB_MODE_WRITEONCE, "pintool",
    "addr", "0x555555555165", "The address of the instruction to inject the fault (in hex).");

KNOB<UINT32> KnobFaultOccurence(KNOB_MODE_WRITEONCE, "pintool",
    "occ", "1", "The Nth time the instruction is executed when the fault should occur.");

std::ofstream out("bitflip.log");

UINT64 flip_count_gpr = 0;
UINT64 flip_count_flags = 0;

// 目标指令执行计数器
UINT32 instruction_exec_count = 0;

// 目标地址变量
ADDRINT TARGET_INSTR_ADDR;
UINT32 TARGET_OCCURENCE;

static inline ADDRINT FlipOneBit(ADDRINT val, UINT32 bit)
{
    ADDRINT flipped = val ^ (1ULL << bit);
    out << "[FLIP] bit " << std::dec << bit
        << ": 0x" << std::hex << val << " to 0x" << flipped << std::dec << std::endl;
    return flipped;
}

/*===============================================
   GPR 翻转 —— 普通指令 AFTER 直接改就行
===============================================*/
VOID DoFlipGpr(CONTEXT *ctxt, REG reg, ADDRINT ip)
{
    instruction_exec_count++;
    // printf("count = %u , occ = %u\n", instruction_exec_count, TARGET_OCCURENCE);
    if( instruction_exec_count != TARGET_OCCURENCE ){
        return; // 只在第 N 次执行时注错
    }

    if( flip_count_gpr >= 1){
        return; //只翻转一次
    }

    if (reg == REG_RSP || reg == REG_RBP)
    {
        return;
    }

    // printf("ip=0x%lx flipping reg %s\n", ip, REG_StringShort(reg).c_str());

    ADDRINT old_val = PIN_GetContextReg(ctxt, reg);
    UINT32 bit = (UINT32)(drand48() * 64);
    ADDRINT new_val = FlipOneBit(old_val, bit);

    PIN_SetContextReg(ctxt, reg, new_val);

    out << "[GPR FLIP #" << ++flip_count_gpr << "] "
        << "Count=" << instruction_exec_count << " "
        << REG_StringShort(reg) << " @0x" << std::hex << ip
        << " bit" << std::dec << bit << "  "
        << "0x" << std::hex << old_val << " to 0x" << new_val << std::dec << std::endl;

    PIN_ExecuteAt(ctxt);
}

/*===============================================
   EFLAGS 翻转
===============================================*/
VOID DoFlipFlags(CONTEXT *ctxt, ADDRINT ip, ADDRINT next_ip)
{
    
    // printf("ip=0x%lx flipping reg %s\n", ip, REG_StringShort(REG_RFLAGS).c_str());
    instruction_exec_count++;
    // printf("count = %u , occ = %u\n", instruction_exec_count, TARGET_OCCURENCE);

    if( instruction_exec_count != TARGET_OCCURENCE ){
        // out << "[FLAGS FLIP #" << flip_count_flags << "] "
        // << "Count=" << instruction_exec_count << " "
        // << "Skipped @0x" << std::hex << ip << std::endl;
        return; // 只在第 N 次执行时注错
    }

    if( flip_count_flags >= 1){
        return; //只翻转一次
    }

    ADDRINT old_flags = PIN_GetContextReg(ctxt, REG_RFLAGS);
    UINT32 bit = (UINT32)(drand48() * 12);
    ADDRINT new_flags = FlipOneBit(old_flags, bit);

    PIN_SetContextReg(ctxt, REG_RFLAGS, new_flags);

    out << "[FLAGS FLIP #" << ++flip_count_flags << "] "
        << "Count=" << instruction_exec_count << " "
        << "@0x" << std::hex << ip << " to next 0x" << next_ip
        << " bit" << std::dec << bit << std::endl;
    
    PIN_ExecuteAt(ctxt);
}

/*===============================================
   插桩逻辑 —— 只对目标地址进行插桩
===============================================*/
VOID Instruction(INS ins, VOID*)
{
    ADDRINT ins_addr = INS_Address(ins);

    // 步骤二：检查是否为目标地址
    if (ins_addr != TARGET_INSTR_ADDR)
    {
        return; 
    }
    
    // 打印指令地址和汇编
    out << "--- TARGET INSTRUCTION FOUND ---\n";
    out << "Instruction at 0x" << std::hex << ins_addr
        << ": " << INS_Disassemble(ins) << std::dec << std::endl;
    
    // GPR 翻转逻辑保持不变，但现在需要注意跳过跳转指令
    if (!(INS_IsBranch(ins) || INS_IsCall(ins) || INS_Category(ins) == XED_CATEGORY_RET))
    {
        // printf("Instrumenting GPR flip at 0x%lx\n", ins_addr);
        // 1. GPR 翻转 —— 只挑写 GPR 的指令
        if (INS_MaxNumWRegs(ins) > 0)
        {
            REG reg_to_flip = REG_INVALID();
            for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); ++i)
            {
                REG r = INS_RegW(ins, i);
                if (REG_is_gr64(r) || REG_is_gr32(r) || REG_is_gr16(r) || REG_is_gr8(r))
                {
                    reg_to_flip = REG_FullRegName(r); 
                    if (REG_is_gr64(reg_to_flip))
                    {
                        break;
                    }
                    break;
                }
            }
            if (REG_valid(reg_to_flip))
            {
                if (INS_IsValidForIpointAfter(ins)) 
                {
                    // IPOINT_AFTER：在指令执行后，其结果已经写入寄存器，此时进行翻转
                    INS_InsertCall(ins, IPOINT_AFTER, // 注意这里是 AFTER
                        AFUNPTR(DoFlipGpr),
                        IARG_CONTEXT,
                        IARG_UINT32, (UINT32)reg_to_flip,
                        IARG_ADDRINT, INS_Address(ins),
                        IARG_END);
                }
            }
        }
    }
    
    // 2. EFLAGS 翻转 —— 只在条件跳转指令执行前翻转 FLAGS
    if (INS_Category(ins) == XED_CATEGORY_COND_BR) // 条件跳转指令
    {
        // printf("Instrumenting FLAGS flip at 0x%lx\n", ins_addr);
        // IPOINT_BEFORE 确保在执行跳转判断前修改 FLAGS
        INS_InsertCall(ins, IPOINT_BEFORE,
            AFUNPTR(DoFlipFlags),
            IARG_CONTEXT,
            IARG_ADDRINT, INS_Address(ins),
            IARG_ADDRINT, INS_NextAddress(ins), // 下一条指令的地址，作为日志记录
            IARG_END);
    }
}

VOID Fini(INT32, VOID*)
{
    out << "=== Finished Successfully ===\n";
    out << "Total GPR flips   : " << flip_count_gpr << "\n";
    out << "Total FLAGS flips : " << flip_count_flags << "\n";
    out.close();
}

int main(int argc, char* argv[])
{
    PIN_InitSymbols();
    // if (PIN_Init(argc, argv)) return 1;
    if (PIN_Init(argc, argv)) 
    {
        std::cerr << "Usage: " << "\n" 
                  << "   -addr <hex_address>: Target instruction address (e.g., 0x555555555165)\n"
                  << "   -occ <number>: Execute fault on the Nth time the instruction is hit (e.g., 5)\n";
        return 1;
    }

    TARGET_INSTR_ADDR = KnobTargetAddr.Value();
    TARGET_OCCURENCE = KnobFaultOccurence.Value();

    srand48(time(0));
    out << "=== Stable Bitflip Injector (Single Address Mode) ===\n";
    out << "Target Address: 0x" << std::hex << TARGET_INSTR_ADDR << std::dec << "\n";
    out << "==================================================\n";
    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddFiniFunction(Fini, 0);

    PIN_StartProgram();
    return 0;
}