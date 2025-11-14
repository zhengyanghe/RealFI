// pc_profiler_final_fixed_v2.cpp
// 修正版 v2：修复延迟测量点、计数时机、TLS 与多线程竞争问题
// **主要修复：Opcode 字符串的内存管理问题（不再在运行时释放）**

#include "pin.H"
#include <fstream>
#include <iostream>
#include <string>
#include <map>
#include <iomanip>
#include <x86intrin.h>
#include <cstring>
#include <cstdlib>

// ---------------- knobs ----------------
KNOB<std::string> KnobOutputFile(KNOB_MODE_WRITEONCE, "pintool",
                                 "o", "pc_profile_fixed.csv", "specify output file name");
KNOB<UINT32> KnobSampleInterval(KNOB_MODE_WRITEONCE, "pintool",
                                "sample_interval", "100", "sample every N dynamic instructions");

// ---------------- globals ----------------
std::ofstream OutFile;
const char CSV_DELIMITER = ',';

PIN_LOCK globalLock; // 保护 map 与文件写

// 结构：每个静态 PC 的累积指标
struct InstMetrics {
    UINT64 count = 0;
    UINT64 totalLatency = 0;
    std::string memLevel = "---";
    // 以后可以扩展 branch count 等
};

std::map<ADDRINT, InstMetrics> instructionMetrics;
// 【新】用于在 Fini 阶段释放 Opcode 字符串内存
std::map<ADDRINT, char*> opcodeStringMap; 

// 统计量（受锁保护）
UINT64 totalDynamicInstr = 0;
UINT64 sampleId = 0;

// TLS 存每线程的 startTsc & 本地计数
struct ThreadData {
    UINT64 startTsc;
    UINT64 localCount; // 用于 per-thread 计数（可选）
    ThreadData() : startTsc(0), localCount(0) {}
};
static TLS_KEY tls_key = INVALID_TLS_KEY;

// ---------------- 辅助函数 (保持不变) ----------------
std::string GetMemLevelByLatency(UINT64 latency) {
    if (latency == 0) return "N/A";
    if (latency < 80)  return "L1";
    if (latency < 250) return "L2";
    if (latency < 800) return "LLC";
    return "DRAM";
}

std::string GetOpcodeCategory(INS ins) {
    if (INS_IsMemoryRead(ins)) return "LOAD";
    if (INS_IsMemoryWrite(ins)) return "STORE";
    if (INS_IsBranch(ins)) return "BRANCH";
    if (INS_IsCall(ins)) return "CALL";
    if (INS_IsRet(ins)) return "RET";
    xed_category_enum_t cat = (xed_category_enum_t)INS_Category(ins);
    if (cat == XED_CATEGORY_LOGICAL) return "LOGIC";
    if (cat == XED_CATEGORY_MMX ||
        cat == XED_CATEGORY_SSE ||
        cat == XED_CATEGORY_AVX ||
        cat == XED_CATEGORY_AVX512) return "FP";
    if (cat == XED_CATEGORY_BINARY) return "ARITH";
    if (INS_Opcode(ins) == XED_ICLASS_NOP) return "NOP";
    if (INS_Opcode(ins) == XED_ICLASS_PAUSE) return "PAUSE";
    return "OTHER";
}

UINT32 GetBranchPathCount(INS ins) {
    if (INS_IsBranch(ins) || INS_IsCall(ins) || INS_IsRet(ins)) {
        return INS_HasFallThrough(ins) ? 2 : 1;
    }
    return 0;
}

UINT32 GetInstructionBitwidth(INS ins) {
    UINT32 maxBits = 0;
    UINT32 memOpIdx = 0;

    for (UINT32 i = 0; i < INS_OperandCount(ins); ++i) {
        if (INS_OperandIsReg(ins, i)) {
            REG reg = INS_OperandReg(ins, i);
            if (REG_valid(reg)) {
                maxBits = std::max(maxBits, REG_Size(reg) * 8);
            }
        }
        else if (INS_OperandIsImmediate(ins, i)) {
            UINT64 imm = INS_OperandImmediate(ins, i);
            UINT32 bits = (imm <= 0xFF) ? 8 : (imm <= 0xFFFF) ? 16 : (imm <= 0xFFFFFFFF) ? 32 : 64;
            maxBits = std::max(maxBits, bits);
        }
    }

    if (INS_IsStandardMemop(ins)) {
        UINT32 memCount = INS_MemoryOperandCount(ins);
        for (UINT32 i = 0; i < INS_OperandCount(ins) && memOpIdx < memCount; ++i) {
            if (INS_OperandIsMemory(ins, i)) {
                UINT32 bytes = INS_MemoryOperandSize(ins, memOpIdx++);
                maxBits = std::max(maxBits, bytes * 8);
            }
        }
    }

    if (maxBits == 0) {
        xed_category_enum_t cat = (xed_category_enum_t)INS_Category(ins);
        if (cat == XED_CATEGORY_AVX512) maxBits = 512;
        else if (cat == XED_CATEGORY_AVX2 || cat == XED_CATEGORY_AVX) maxBits = 256;
        else if (cat == XED_CATEGORY_SSE) maxBits = 128;
        else if (cat == XED_CATEGORY_MMX) maxBits = 64;
        else maxBits = 64;
    }

    return maxBits;
}

// ---------------- TLS helpers (保持不变) ----------------
inline ThreadData* GetThreadData(THREADID tid) {
    void* p = PIN_GetThreadData(tls_key, tid);
    return static_cast<ThreadData*>(p);
}

inline UINT64 GetStartTsc(THREADID tid) {
    ThreadData* td = GetThreadData(tid);
    return td ? td->startTsc : 0;
}
inline void SetStartTsc(THREADID tid, UINT64 tsc) {
    ThreadData* td = GetThreadData(tid);
    if (td) td->startTsc = tsc;
}

// ---------------- runtime callbacks ----------------

// 在每条指令执行之前记录 startTsc
VOID InstructionStart(THREADID tid) {
    _mm_lfence();
    SetStartTsc(tid, __rdtsc());
}

// 在指令执行之后读取 endTsc 并累积 latency
VOID InstructionEnd(THREADID tid, ADDRINT pc) {
    _mm_lfence();
    UINT64 endTsc = __rdtsc();
    UINT64 startTsc = GetStartTsc(tid);
    if (startTsc == 0 || endTsc <= startTsc) {
        SetStartTsc(tid, 0);
        return;
    }
    UINT64 latency = endTsc - startTsc;

    PIN_GetLock(&globalLock, 1);
    {
        auto &m = instructionMetrics[pc];
        m.totalLatency += latency;
        // 第一次测量到有效延迟时更新 MemLevel
        if (m.memLevel == "N/A" || m.memLevel == "---") {
             m.memLevel = GetMemLevelByLatency(latency);
        }
    }
    PIN_ReleaseLock(&globalLock);

    SetStartTsc(tid, 0);
}

// 写一条采样记录到文件（runtime）
// 【修改】移除 free(opcode_cstr)
VOID RecordPC_Runtime(ADDRINT pc, char* opcode_cstr, UINT32 bitwidth, UINT32 branchCnt) {
    double avgLatency = 0.0;
    UINT64 execCount = 0;
    std::string memLevel = "---";

    // 读取该 pc 的累积信息（加锁读取）
    PIN_GetLock(&globalLock, 1);
    {
        auto it = instructionMetrics.find(pc);
        if (it != instructionMetrics.end()) {
            execCount = it->second.count;
            memLevel = it->second.memLevel;
            if (it->second.count > 0) {
                avgLatency = static_cast<double>(it->second.totalLatency) / it->second.count;
            }
        }
        // 输出到文件（仍在锁内，保证写入不会被并发打断）
        if (strcmp(opcode_cstr, "LOAD") != 0 && strcmp(opcode_cstr, "STORE") != 0) {
            memLevel = "N/A";
        }
        OutFile << sampleId++ << CSV_DELIMITER
                << "0x" << std::hex << pc << std::dec << CSV_DELIMITER
                << (opcode_cstr ? opcode_cstr : "UNKNOWN") << CSV_DELIMITER
                << bitwidth << CSV_DELIMITER
                << execCount << CSV_DELIMITER
                << std::fixed << std::setprecision(2) << avgLatency << CSV_DELIMITER
                << memLevel << CSV_DELIMITER
                << branchCnt << std::endl;
    }
    PIN_ReleaseLock(&globalLock);
    
    // 【移除】 if (opcode_cstr) free(opcode_cstr); // 移除：由 Fini 统一释放
}

// 每条动态指令都会调用（在 IPOINT_BEFORE）用于计数与采样判定
// 【修改】移除未采样时的 free(opcode_cstr)
VOID CountAndMaybeSample(THREADID tid, ADDRINT pc, char* opcode_cstr, UINT32 bitwidth, UINT32 branchCnt) {
    // 增加总计数（受锁）
    PIN_GetLock(&globalLock, 1);
    totalDynamicInstr++;
    PIN_ReleaseLock(&globalLock);

    // per-thread 本地计数（非必须，但给出示例）
    ThreadData* td = GetThreadData(tid);
    if (td) td->localCount++;

    // 更新该 pc 的执行次数（受锁）
    PIN_GetLock(&globalLock, 1);
    instructionMetrics[pc].count++;
    // 本次是否采样由全局计数决定
    UINT64 currentTotal = totalDynamicInstr;
    PIN_ReleaseLock(&globalLock);

    UINT32 sampleInterval = KnobSampleInterval.Value();
    if (sampleInterval == 0) sampleInterval = 1;

    if (currentTotal % sampleInterval == 0) {
        // 采样：直接在运行时写入一条记录。
        // opcode_cstr 是静态插桩时 strdup 的一块内存，其生命周期由 opcodeStringMap 保护。
        RecordPC_Runtime(pc, opcode_cstr, bitwidth, branchCnt);
    } 
    // 【移除】else { 
    // 【移除】    // 没被采样的路径：必须释放 opcode_cstr，因为我们在静态插桩时 strdup 了
    // 【移除】    if (opcode_cstr) free(opcode_cstr); // 移除：由 Fini 统一释放
    // 【移除】}
}

// ---------------- 插桩 ----------------
VOID Instruction(INS ins, VOID *v) {
    ADDRINT pc = INS_Address(ins);

    // 预置 InstMetrics 和 Opcode 字符串
    PIN_GetLock(&globalLock, 1);
    {
        // 确保 InstMetrics 存在
        auto &m = instructionMetrics[pc];
        if (INS_IsMemoryRead(ins) || INS_IsMemoryWrite(ins)) {
            if (m.memLevel == "---") m.memLevel = "N/A";
        }

        // 【新】分配并存储 opcode 字符串，只执行一次
        if (opcodeStringMap.find(pc) == opcodeStringMap.end()) {
            std::string opcode_str = GetOpcodeCategory(ins);
            char* opcode_cstr = strdup(opcode_str.c_str());
            opcodeStringMap[pc] = opcode_cstr; // 存储指针，避免在运行时释放
        }
    }
    PIN_ReleaseLock(&globalLock);
    
    // 【新】从 map 中获取静态分配的指针，传入运行时回调
    char* opcode_cstr_static = opcodeStringMap[pc]; 

    // 计算静态信息（在插桩阶段计算，传入运行时回调）
    UINT32 bits = GetInstructionBitwidth(ins);
    UINT32 branchCnt = GetBranchPathCount(ins);

    // 插入 runtime 计数/采样（在执行前）
    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)CountAndMaybeSample,
                   IARG_THREAD_ID,
                   IARG_INST_PTR,
                   IARG_PTR, opcode_cstr_static, // 【新】传入静态指针
                   IARG_UINT32, bits,
                   IARG_UINT32, branchCnt,
                   IARG_END);

    // 插入延迟测量 start / end（保持不变）
    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)InstructionStart,
                   IARG_THREAD_ID, IARG_END);
    if(INS_IsValidForIpointAfter(ins)) {
        INS_InsertCall(ins, IPOINT_AFTER, (AFUNPTR)InstructionEnd, IARG_THREAD_ID, IARG_INST_PTR, IARG_END);
    }
}

// ---------------- 线程生命周期 (保持不变) ----------------
VOID ThreadStart(THREADID tid, CONTEXT *ctxt, INT32 flags, VOID *v) {
    ThreadData* td = new ThreadData();
    PIN_SetThreadData(tls_key, td, tid);
}

VOID ThreadFini(THREADID tid, const CONTEXT *ctxt, INT32 code, VOID *v) {
    ThreadData* td = GetThreadData(tid);
    if (td) {
        delete td;
        PIN_SetThreadData(tls_key, nullptr, tid);
    }
}

// ---------------- fini ----------------
// 【修改】添加了对 opcodeStringMap 的内存清理
VOID Fini(INT32 code, VOID *v) {
    PIN_GetLock(&globalLock, 1);
    OutFile << "----------------------------------------" << std::endl;
    OutFile << "# Total dynamic instructions: " << totalDynamicInstr << std::endl;
    OutFile << "# Sampled PCs: " << sampleId << std::endl;
    OutFile << "# Unique static PCs: " << instructionMetrics.size() << std::endl;
    PIN_ReleaseLock(&globalLock);

    // 【新】清理 Opcode 字符串占用的内存
    for (auto const& [pc, cstr] : opcodeStringMap) {
        if (cstr) {
            free(cstr);
        }
    }
    opcodeStringMap.clear();

    OutFile.close();
}

// ---------------- usage (保持不变) ----------------
INT32 Usage() {
    std::cerr << "PC Profiler (fixed v2): samples every N dynamic instructions.\n";
    std::cerr << KNOB_BASE::StringKnobSummary() << std::endl;
    return -1;
}

// ---------------- main (保持不变) ----------------
int main(int argc, char *argv[]) {
    if (PIN_Init(argc, argv)) return Usage();

    PIN_InitSymbols();

    // 初始化 TLS key 与锁
    tls_key = PIN_CreateThreadDataKey(NULL);
    if (tls_key == INVALID_TLS_KEY) {
        std::cerr << "Failed to create TLS key!" << std::endl;
        return -1;
    }
    PIN_InitLock(&globalLock);

    OutFile.open(KnobOutputFile.Value().c_str());
    if (!OutFile.is_open()) {
        std::cerr << "Cannot open output file: " << KnobOutputFile.Value() << std::endl;
        return -1;
    }

    OutFile << "ID" << CSV_DELIMITER
            << "PC" << CSV_DELIMITER
            << "Opcode" << CSV_DELIMITER
            << "Bitwidth" << CSV_DELIMITER
            << "Execution_Count" << CSV_DELIMITER
            << "Avg_Latency" << CSV_DELIMITER
            << "MemLevel" << CSV_DELIMITER
            << "BranchCount" << std::endl;

    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddThreadStartFunction(ThreadStart, 0);
    PIN_AddThreadFiniFunction(ThreadFini, 0);
    PIN_AddFiniFunction(Fini, 0);

    // 启动被测程序
    PIN_StartProgram();
    return 0;
}