#include "pin.H"
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <ctime>

// 引入复杂注错相关的数据结构和辅助函数（RegMap, FI_SetXMMContextReg 等）
#include "faultinjection.h"
#include "fi_cjmp_map.h"

using std::cerr;
using std::cout;
using std::endl;

bool success = false;

// ===================== Knobs：地址 + 第 N 次执行 =====================

// 目标指令地址（静态 IP）
KNOB<ADDRINT> KnobTargetAddr(
    KNOB_MODE_WRITEONCE, "pintool",
    "addr", "0x0",
    "The address of the instruction to inject the fault (in hex).");

// 在该指令的第 N 次动态执行时注错
KNOB<UINT32> KnobFaultOccurence(
    KNOB_MODE_WRITEONCE, "pintool",
    "occ", "1",
    "The Nth time the instruction is executed when the fault should occur.");

std::ofstream out("bitflip.log");

// ============= 全局状态：只对一个地址、只注一次 =================

ADDRINT TARGET_INSTR_ADDR = 0;
UINT32  TARGET_OCCURENCE  = 1;

// 目标指令已执行次数（动态）
static UINT64 g_hitCount = 0;
// 是否已经执行过一次注错
static BOOL   g_injected  = FALSE;

// 统计信息（可选）
static UINT64 flip_count_reg   = 0;
static UINT64 flip_count_flags = 0;

// 条件跳转 map，用于复杂 flags 注错
CJmpMap jmp_map;

// ==================== Helper：命中 + N 次条件 =======================
//
// 返回：是否应该在本次调用中真实注错
// 每次目标指令被执行，对应的注错函数都会调用一次该逻辑
//
static inline bool ShouldInjectThisTime()
{
    if (g_injected) {
        return false;   // 已经注过一次，不再注
    }

    g_hitCount++;

    if (g_hitCount != TARGET_OCCURENCE) {
        return false;   // 还没到第 N 次
    }

    // 第 N 次命中，可以注错
    return true;
}

// ===================================================================
// 复杂寄存器 / 浮点寄存器 注错（基于 faultinjection.cpp::inject_CCS）
// ===================================================================
//
// ip      : 当前指令地址（仅用于日志）
// reg_num : 在 RegMap 中的 index
// ctxt    : PIN 上下文
//
VOID ComplexInjectReg(VOID *ip, UINT32 reg_num, CONTEXT *ctxt)
{
    if (!ShouldInjectThisTime()) {
        return;
    }

    const REG reg = reg_map.findInjectReg(reg_num);
    bool isvalid = false;

    if (REG_valid(reg)) {
        isvalid = true;

        // 浮点寄存器（xmm/ymm/x87/mm 等）
        if (reg_map.isFloatReg(reg_num)) {
            if (REG_is_xmm(reg)) {
                PRINT_MESSAGE(4, ("Executing: xmm Reg %s\n", REG_StringShort(reg).c_str()));
                FI_SetXMMContextReg(ctxt, reg, reg_num);
            } else if (REG_is_ymm(reg)) {
                PRINT_MESSAGE(4, ("Executing: ymm Reg %s\n", REG_StringShort(reg).c_str()));
                FI_SetYMMContextReg(ctxt, reg, reg_num);
            } else if (REG_is_fr(reg) || REG_is_mm(reg)) {
                PRINT_MESSAGE(4, ("Executing: mm/x87 Reg %s\n", REG_StringShort(reg).c_str()));
                FI_SetSTContextReg(ctxt, reg, reg_num);
            } else {
                fprintf(stderr, "Register %s not covered in FP path!\n",
                        REG_StringShort(reg).c_str());
                exit(3);
            }
        }
        // 整型寄存器
        else {
            ADDRINT temp = PIN_GetContextReg(ctxt, reg);

            // 根据 RegMap 中记录的位宽限制注入范围
            UINT32 low_bound_bit  = reg_map.findLowBoundBit(reg_num);
            UINT32 high_bound_bit = reg_map.findHighBoundBit(reg_num);

            srand((unsigned)time(0));
            UINT32 inject_bit = (rand() % (high_bound_bit - low_bound_bit)) + low_bound_bit;

            temp = (ADDRINT)(temp ^ (1UL << inject_bit));
            PIN_SetContextReg(ctxt, reg, temp);

            out << "[REG FLIP #" << (flip_count_reg + 1) << "] "
                << "IP=" << ip << " "
                << "Reg=" << REG_StringShort(reg)
                << " bit=" << inject_bit
                << std::endl;
        }
    }

    if (isvalid) {
        flip_count_reg++;
        g_injected = TRUE;       // 只注一次
        PIN_ExecuteAt(ctxt);     // 让上下文从修改后的状态继续执行
    }
}

// ===================================================================
// 复杂 Flags + 条件跳转 注错（基于 FI_InjectFault_FlagReg）
// ===================================================================
//
// ip      : 当前指令地址
// reg_num : RFLAGS 在 RegMap 中的 index
// jmp_num : 条件跳转类型 index（来自 CJmpMap）
// ctxt    : PIN 上下文
//
VOID ComplexInjectFlags(VOID *ip, UINT32 reg_num, UINT32 jmp_num, CONTEXT* ctxt)
{
    if (!ShouldInjectThisTime()) {
        return;
    }

    bool isvalid = false;
    const REG reg = reg_map.findInjectReg(reg_num);

    if (REG_valid(reg)) {
        isvalid = true;

        CJmpMap::JmpType jmptype = jmp_map.findJmpType(jmp_num);

        ADDRINT temp = PIN_GetContextReg(ctxt, reg);
        PRINT_MESSAGE(3, ("EXECUTING flag reg: Original %s value %p\n",
                          REG_StringShort(reg).c_str(), (VOID*)temp));

        if (jmptype == CJmpMap::DEFAULT) {
            // 默认：翻转某一位
            UINT32 inject_bit = jmp_map.findInjectBit(jmp_num);
            temp = temp ^ (1UL << inject_bit);
        } else if (jmptype == CJmpMap::USPECJMP) {
            // USPECJMP 逻辑：根据 CF/ZF 调整，制造错误跳转
            UINT32 CF_val = (temp & (1UL << CF_BIT)) >> CF_BIT;
            UINT32 ZF_val = (temp & (1UL << ZF_BIT)) >> ZF_BIT;

            if (CF_val || ZF_val) {
                temp = temp & (~(1UL << CF_BIT));
                temp = temp & (~(1UL << ZF_BIT));
            } else {
                temp = temp | (1UL << ZF_BIT);
            }
        } else {
            // 其他类型：基于 SF/OF/ZF 组合修改
            UINT32 SF_val = (temp & (1UL << SF_BIT)) >> SF_BIT;
            UINT32 OF_val = (temp & (1UL << OF_BIT)) >> OF_BIT;
            UINT32 ZF_val = (temp & (1UL << ZF_BIT)) >> ZF_BIT;

            if (ZF_val || (SF_val != OF_val)) {
                temp = temp & (~(1UL << ZF_BIT));
                if (SF_val != OF_val) {
                    temp = temp ^ (1UL << SF_BIT);
                }
            } else {
                temp = temp | (1UL << ZF_BIT);
            }
        }

        PIN_SetContextReg(ctxt, reg, temp);

        PRINT_MESSAGE(3, ("EXECUTING flag reg: Changed %s value %p\n",
                          REG_StringShort(reg).c_str(),
                          (VOID*)PIN_GetContextReg(ctxt, reg)));

        out << "[FLAGS FLIP #" << (flip_count_flags + 1) << "] "
            << "IP=" << ip << " Reg=" << REG_StringShort(reg) << std::endl;
    }

    if (isvalid) {
        flip_count_flags++;
        g_injected = TRUE;
        PIN_ExecuteAt(ctxt);
    }
}

// ===================================================================
// 插桩逻辑：只对 TARGET_INSTR_ADDR 这一个指令插桩
// ===================================================================
VOID Instruction(INS ins, VOID*)
{
  ADDRINT ins_addr = INS_Address(ins);

    if (ins_addr != TARGET_INSTR_ADDR) {
        return;  // 只关心一个静态 IP
    }

    out << "--- TARGET INSTRUCTION FOUND ---\n";
    out << "Instruction at 0x" << std::hex << ins_addr << ": "
        << INS_Disassemble(ins) << std::dec << std::endl;

    // out << "0";

    INT32 numW = INS_MaxNumWRegs(ins);
    out << "numW=" << numW << "\n";
    if (numW <= 0) {
        // 没有写寄存器，就不注 GPR/FP，看看是否是 flag->cond_br 的情况
        // （极少见，这里简单跳过）
        return;
    }
    // out << "1";

    // 默认选择一个写寄存器（可根据需要改成 random() % numW）
    UINT32 randW = 0;
    REG reg = INS_RegW(ins, randW);

    if (!REG_valid(reg)) {
        return;
    }
    // out << "2";

    // 如果是 flags 并且下一条是条件跳转，则使用复杂 flag 注错逻辑
    if (reg == REG_RFLAGS || reg == REG_EFLAGS || reg == REG_FLAGS) {
        INS next_ins = INS_Next(ins);
        if (INS_Valid(next_ins) &&
            INS_Category(next_ins) == XED_CATEGORY_COND_BR) {

            UINT32 reg_index = reg_map.findRegIndex(reg);
            UINT32 jmp_index = jmp_map.findJmpIndex(
                OPCODE_StringShort(INS_Opcode(next_ins)));

            INS_InsertCall(ins, IPOINT_AFTER,
                           AFUNPTR(ComplexInjectFlags),
                           IARG_INST_PTR,
                           IARG_UINT32, reg_index,
                           IARG_UINT32, jmp_index,
                           IARG_CONTEXT,
                           IARG_END);
            return;
        }
    }
    // out << "3";

    // 否则使用复杂通用寄存器/浮点寄存器注错逻辑
    UINT32 reg_index = reg_map.findRegIndex(reg);

    INS_InsertCall(ins, IPOINT_AFTER, AFUNPTR(ComplexInjectReg), IARG_INST_PTR,
                   IARG_UINT32, reg_index, IARG_CONTEXT, IARG_END);
    // out << "4";
}

// ===================================================================
// Fini：简单打印统计
// ===================================================================
VOID Fini(INT32, VOID*)
{
    out << "=== Finished Successfully ===\n";
    out << "Target Address      : 0x" << std::hex << TARGET_INSTR_ADDR << std::dec << "\n";
    out << "Target Occurence(N) : " << TARGET_OCCURENCE << "\n";
    out << "Hit Count           : " << g_hitCount << "\n";
    out << "Injected?           : " << (g_injected ? "YES" : "NO") << "\n";
    out << "Total REG flips     : " << flip_count_reg << "\n";
    out << "Total FLAGS flips   : " << flip_count_flags << "\n";
    out.close();

    if (g_injected) {
        success = true;
    }

    std::cout << "Successful termination: "
              << (g_injected ? "YES" : "NO") << std::endl;
}

// ===================================================================
// main
// ===================================================================
int main(int argc, char* argv[])
{
    PIN_InitSymbols();

    if (PIN_Init(argc, argv)) {
        std::cerr << "Usage:\n"
                  << "   -addr <hex_address>  : Target instruction address (e.g., 0x400c52)\n"
                  << "   -occ  <number>       : Inject fault on the Nth time the instruction is hit\n";
        return 1;
    }

    TARGET_INSTR_ADDR = KnobTargetAddr.Value();
    TARGET_OCCURENCE  = KnobFaultOccurence.Value();

    if (TARGET_INSTR_ADDR == 0) {
        std::cerr << "[ERROR] Please specify a valid -addr\n";
        return 1;
    }

    out << "=== Complex Bitflip Injector (Single Address Mode) ===\n";
    out << "Target Address      : 0x" << std::hex << TARGET_INSTR_ADDR << std::dec << "\n";
    out << "Target Occurence(N) : " << TARGET_OCCURENCE << "\n";
    out << "======================================================\n";

    // 只对一条指令插桩
    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddFiniFunction(Fini, 0);

    PIN_StartProgram();

    printf("Successful termination: %s\n", success ? "YES" : "NO");
    return 0;
}
