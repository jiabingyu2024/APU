#include <stdint.h>
#include "model_layout.h"

#define CONSOLE_BASE       0x10000000u
#define CONSOLE_TXDATA     (CONSOLE_BASE + 0x00u)
#define CONSOLE_DEBUG      (CONSOLE_BASE + 0x04u)
#define CONSOLE_STATUS     (CONSOLE_BASE + 0x08u)
#define CONSOLE_EXIT       (CONSOLE_BASE + 0x0cu)
#define TIMER_BASE         0x10001000u
#define TIMER_COUNT_LO     (TIMER_BASE + 0x00u)
#define TIMER_COMPARE_LO   (TIMER_BASE + 0x08u)
#define TIMER_CONTROL      (TIMER_BASE + 0x0cu)
#define RAM_TEST_BASE      0x0000e000u
#define UNMAPPED_TEST_ADDR 0x30000000u
#define APU_BASE           0x20000000u
#define APU_WINDOW         (APU_BASE + 0x0000u)
#define APU_RAM_CTRL       (APU_BASE + 0x2000u)
#define APU_RAM_SEL        (APU_BASE + 0x2004u)
#define APU_READY          (APU_BASE + 0x2008u)
#define APU_CPL            (APU_BASE + 0x200cu)
#define MODEL_BASE         0x40000000u

#define APU_SEL_BN0        0u
#define APU_SEL_WEIGHT0    64u
#define APU_SEL_ACT        128u
#define APU_SEL_OUT        129u
#define APU_SEL_WORKSHEET  130u

#define APU_ZERO_CONV_INSTRUCTION 0x3acc8000u
#define APU_FEATURE_WORDS          1024u
#define APU_WEIGHT_BANKS           64u
#define APU_WEIGHT_WORDS_PER_BANK  9u
#define APU_COMPLETION_TIMEOUT     200000u

typedef struct {
    uint32_t weight_offset;
    uint32_t bn_offset;
    uint32_t instruction;
    uint32_t weight_base;
    uint32_t bn_base;
    uint32_t worksheet_index;
    uint32_t weight_words_per_bank;
    uint32_t output_groups;
} apu_operation_t;

static const apu_operation_t network_operations[] = {
    {MODEL_L10_CONV1_OFFSET, MODEL_L10_BN1_OFFSET, 0x3acc8000u, 0u,   0u,  0u, 18u, 1u},
    {MODEL_L10_CONV2_OFFSET, MODEL_L10_BN3_OFFSET, 0x3acc8121u, 9u,   1u,  1u, 18u, 1u},
    {MODEL_L11_CONV1_OFFSET, MODEL_L11_BN1_OFFSET, 0x3acc8242u, 18u,  2u,  2u, 18u, 1u},
    {MODEL_L11_CONV2_OFFSET, MODEL_L11_BN3_OFFSET, 0x3acc8363u, 27u,  3u,  3u, 18u, 1u},
    {MODEL_L20_CONV1_OFFSET, MODEL_L20_BN1_OFFSET, 0x3acf0484u, 36u,  4u,  4u, 18u, 2u},
    {MODEL_L20_RESIDUAL_OFFSET, MODEL_L20_BN3_OFFSET, 0x78eec6c6u, 54u, 6u, 5u, 38u, 2u},
    {MODEL_L21_CONV1_OFFSET, MODEL_L21_BN1_OFFSET, 0x38ee8b8au, 92u, 10u, 6u, 36u, 2u},
    {MODEL_L21_CONV2_OFFSET, MODEL_L21_BN3_OFFSET, 0x38ee900eu, 128u, 14u, 7u, 36u, 2u},
    {MODEL_L30_CONV1_OFFSET, MODEL_L30_BN1_OFFSET, 0x38f10000u, 0u, 0u, 0u, 36u, 4u},
    {MODEL_L30_RESIDUAL_OFFSET, MODEL_L30_BN3_OFFSET, 0x7710c000u, 0u, 0u, 0u, 76u, 4u},
    {MODEL_L31_CONV1_OFFSET, MODEL_L31_BN1_OFFSET, 0x37108000u, 0u, 0u, 0u, 72u, 4u},
    {MODEL_L31_CONV2_OFFSET, MODEL_L31_BN3_OFFSET, 0x37108000u, 0u, 0u, 0u, 72u, 4u},
};

static inline void mmio_write32(uint32_t address, uint32_t value)
{
    *(volatile uint32_t *)address = value;
}

static inline uint32_t mmio_read32(uint32_t address)
{
    return *(volatile uint32_t *)address;
}

static inline uint32_t model_read32(uint32_t word_offset)
{
    return mmio_read32(MODEL_BASE + word_offset * 4u);
}

static inline void debug_set(uint32_t code)
{
    mmio_write32(CONSOLE_DEBUG, code);
}

static void putc(char value)
{
    while ((mmio_read32(CONSOLE_STATUS) & 1u) == 0u) {
    }
    mmio_write32(CONSOLE_TXDATA, (uint32_t)(uint8_t)value);
}

static void puts(const char *text)
{
    while (*text != '\0') {
        putc(*text++);
    }
}

static void put_hex(uint32_t value)
{
    static const char digits[] = "0123456789abcdef";

    for (int shift = 28; shift >= 0; shift -= 4) {
        putc(digits[(value >> (uint32_t)shift) & 0x0fu]);
    }
}

static void fail(uint32_t code)
{
    debug_set(0x80u | (code & 0x7fu));
    puts("FAIL code=0x");
    put_hex(code);
    putc('\n');
    mmio_write32(CONSOLE_EXIT, code);
    for (;;) {
    }
}

static void apu_select(uint32_t target)
{
    mmio_write32(APU_RAM_SEL, target);
}

static void apu_write64(uint32_t index, uint64_t value)
{
    mmio_write32(APU_WINDOW + index * 8u, (uint32_t)value);
    mmio_write32(APU_WINDOW + index * 8u + 4u, (uint32_t)(value >> 32));
}

static uint64_t apu_read64(uint32_t index)
{
    uint32_t low = mmio_read32(APU_WINDOW + index * 8u);
    uint32_t high = mmio_read32(APU_WINDOW + index * 8u + 4u);
    return ((uint64_t)high << 32) | low;
}

static void apu_start_and_wait(uint32_t timeout_code)
{
    uint32_t completed = 0u;

    mmio_write32(APU_RAM_CTRL, 0u);
    mmio_write32(APU_READY, 1u);

    // CPL is sticky but read-to-clear. The successful read returns one and
    // simultaneously prepares int_cal for the next APU batch.
    for (uint32_t wait = 0; wait < APU_COMPLETION_TIMEOUT; wait++) {
        if ((mmio_read32(APU_CPL) & 1u) != 0u) {
            completed = 1u;
            break;
        }
    }
    if (completed == 0u) fail(timeout_code);

    // Ctrl emits the final SRAM write through registered controls after
    // WorkSheetDone. Keep compute ownership long enough for that tail write.
    for (volatile uint32_t fence = 0; fence < 16u; fence++) {
    }
    mmio_write32(APU_RAM_CTRL, 3u);
}

static void apu_load_model_words(uint32_t model_offset, uint32_t apu_byte_offset,
                                 uint32_t word_count)
{
    for (uint32_t index = 0; index < word_count; index++) {
        mmio_write32(APU_WINDOW + apu_byte_offset + index * 4u,
                     model_read32(model_offset + index));
    }
}

static void apu_load_operation(const apu_operation_t *operation)
{
    for (uint32_t group = 0; group < operation->output_groups; group++) {
        for (uint32_t bank = 0; bank < APU_WEIGHT_BANKS; bank++) {
            uint32_t source = operation->weight_offset +
                              (group * APU_WEIGHT_BANKS + bank) *
                              operation->weight_words_per_bank;
            uint32_t destination = operation->weight_base * 8u +
                                   group * operation->weight_words_per_bank * 4u;

            apu_select(APU_SEL_WEIGHT0 + bank);
            apu_load_model_words(source, destination,
                                 operation->weight_words_per_bank);
        }
    }

    for (uint32_t group = 0; group < operation->output_groups; group++) {
        for (uint32_t channel = 0; channel < APU_WEIGHT_BANKS; channel++) {
            apu_select(APU_SEL_BN0 + channel);
            mmio_write32(APU_WINDOW + (operation->bn_base + group) * 4u,
                         model_read32(operation->bn_offset +
                                      group * APU_WEIGHT_BANKS + channel));
        }
    }

    apu_select(APU_SEL_WORKSHEET);
    mmio_write32(APU_WINDOW + operation->worksheet_index * 4u,
                 operation->instruction);
}

static void apu_run_full_network(void)
{
    mmio_write32(APU_RAM_CTRL, 3u);

    // The input file already follows the APU low32/high32 write order.
    apu_select(APU_SEL_ACT);
    apu_load_model_words(MODEL_INPUT_OFFSET, 0u, MODEL_INPUT_WORDS);

    // Instructions 0..7 share one resident weight image and one WorkSheet run.
    for (uint32_t index = 0; index < 8u; index++) {
        apu_load_operation(&network_operations[index]);
    }
    apu_start_and_wait(0x30u);
    debug_set(0x51u);

    // Layer3 does not fit beside the earlier weights. Reuse weight/BN/worksheet
    // address zero and execute each operation as an independent batch.
    for (uint32_t index = 8u; index < 12u; index++) {
        apu_load_operation(&network_operations[index]);
        apu_start_and_wait(0x31u + index - 8u);
        debug_set(0x52u + index - 8u);
    }

    // Twelve ping-pong toggles return the final 8x8x256 tensor to ActSRAM.
    // Physical groups are 3,2,1,0 while the golden file is canonical 0,1,2,3.
    apu_select(APU_SEL_ACT);
    for (uint32_t pixel = 0; pixel < 64u; pixel++) {
        for (uint32_t group = 0; group < 4u; group++) {
            uint32_t physical_index = pixel * 4u + (3u - group);
            uint32_t golden_index = MODEL_FINAL_GOLDEN_OFFSET +
                                    (pixel * 4u + group) * 2u;
            uint64_t expected = ((uint64_t)model_read32(golden_index) << 32) |
                                model_read32(golden_index + 1u);
            uint64_t actual = apu_read64(physical_index);

            if (actual != expected) {
                puts("FULL mismatch pixel=0x");
                put_hex(pixel);
                puts(" group=0x");
                put_hex(group);
                putc('\n');
                fail(0x36u);
            }
        }
    }

    debug_set(0x5fu);
    puts("APU FULL NETWORK PASS\n");
}

static void apu_mmio_smoke(void)
{
    const uint64_t act_value = UINT64_C(0x01234567deadbeef);
    const uint64_t out_value = UINT64_C(0x89abcdef76543210);
    const uint64_t weight_value = UINT64_C(0xfedcba9876543210);
    const uint32_t bn_value = 0x000012a5u;
    const uint32_t worksheet_value = 0x12345678u;

    mmio_write32(APU_RAM_CTRL, 3u);
    if (mmio_read32(APU_RAM_CTRL) != 3u) fail(0x10u);

    apu_select(APU_SEL_ACT);
    if (mmio_read32(APU_RAM_SEL) != APU_SEL_ACT) fail(0x11u);
    apu_write64(7u, act_value);
    if (apu_read64(7u) != act_value) fail(0x12u);

    // APU only accepts aligned full-word accesses. This byte store must be dropped.
    *(volatile uint8_t *)(APU_WINDOW + 7u * 8u) = 0u;
    if (apu_read64(7u) != act_value) fail(0x13u);

    apu_select(APU_SEL_OUT);
    apu_write64(9u, out_value);
    if (apu_read64(9u) != out_value) fail(0x14u);

    apu_select(APU_SEL_WEIGHT0);
    apu_write64(3u, weight_value);
    if (apu_read64(3u) != weight_value) fail(0x15u);

    apu_select(APU_SEL_BN0 + 5u);
    mmio_write32(APU_WINDOW + 2u * 4u, bn_value);
    if (mmio_read32(APU_WINDOW + 2u * 4u) != (bn_value & 0x1fffu)) fail(0x16u);

    apu_select(APU_SEL_WORKSHEET);
    mmio_write32(APU_WINDOW, worksheet_value);
    if (mmio_read32(APU_WINDOW) != worksheet_value) fail(0x17u);

    debug_set(0x7eu);
    puts("APU MMIO BRIDGE PASS\n");
}

static void apu_load_zero_conv(void)
{
    // CPU owns feature RAM and weight RAM while loading parameters.
    mmio_write32(APU_RAM_CTRL, 3u);

    // One 64-bit word stores 64 input channels at one spatial position.
    apu_select(APU_SEL_ACT);
    for (uint32_t index = 0; index < APU_FEATURE_WORDS; index++) {
        apu_write64(index, UINT64_C(0));
    }

    // The selected instruction is 3x3, Cin=64 and Cout=64. Therefore each
    // output lane/bank consumes exactly nine 64-bit weight words.
    for (uint32_t bank = 0; bank < APU_WEIGHT_BANKS; bank++) {
        apu_select(APU_SEL_WEIGHT0 + bank);
        for (uint32_t index = 0; index < APU_WEIGHT_WORDS_PER_BANK; index++) {
            apu_write64(index, UINT64_C(0));
        }
    }

    // direction=0 and threshold=4095 means output bit = (accumulator < 4095).
    // This 3x3/Cin64 instruction can accumulate at most 9*64=576, so every
    // output lane must become one regardless of border padding or pipe fill.
    for (uint32_t channel = 0; channel < APU_WEIGHT_BANKS; channel++) {
        apu_select(APU_SEL_BN0 + channel);
        mmio_write32(APU_WINDOW, 0x0fffu);
    }

    apu_select(APU_SEL_WORKSHEET);
    mmio_write32(APU_WINDOW, APU_ZERO_CONV_INSTRUCTION);
}

static void apu_run_zero_conv(void)
{
    apu_load_zero_conv();
    apu_start_and_wait(0x20u);
    apu_select(APU_SEL_OUT);
    for (uint32_t index = 0; index < APU_FEATURE_WORDS; index++) {
        uint64_t actual = apu_read64(index);
        if (actual != UINT64_MAX) {
            puts("APU result mismatch index=0x");
            put_hex(index);
            puts(" high=0x");
            put_hex((uint32_t)(actual >> 32));
            puts(" low=0x");
            put_hex((uint32_t)actual);
            putc('\n');
            fail(0x21u);
        }
    }

    debug_set(0x6fu);
    puts("APU ZERO CONV PASS\n");
}

int main(void)
{
    volatile uint8_t *ram8 = (volatile uint8_t *)RAM_TEST_BASE;
    volatile uint16_t *ram16 = (volatile uint16_t *)(RAM_TEST_BASE + 4u);
    volatile uint32_t *ram32 = (volatile uint32_t *)(RAM_TEST_BASE + 8u);
    volatile uint32_t factor_a = 123u;
    volatile uint32_t factor_b = 17u;
    uint32_t timer_start;
    uint32_t timer_end;
    uint32_t product;
    uint32_t quotient;

    debug_set(0x01u);
    puts("HELLO RISCV APU SOC\n");

    ram8[0] = 0x5au;
    ram8[1] = 0xa5u;
    ram16[0] = 0x1357u;
    ram32[0] = 0x89abcdefu;
    if (ram8[0] != 0x5au || ram8[1] != 0xa5u || ram16[0] != 0x1357u ||
        ram32[0] != 0x89abcdefu) {
        fail(0x01u);
    }
    debug_set(0x10u);
    puts("RAM BYTE/HALF/WORD PASS\n");

    product = factor_a * factor_b;
    quotient = product / factor_b;
    if (product != 2091u || quotient != factor_a) {
        fail(0x02u);
    }
    debug_set(0x20u);
    puts("RV32IM PASS\n");

    timer_start = mmio_read32(TIMER_COUNT_LO);
    for (volatile uint32_t index = 0; index < 64u; index++) {
    }
    timer_end = mmio_read32(TIMER_COUNT_LO);
    if (timer_end <= timer_start) {
        fail(0x03u);
    }
    debug_set(0x30u);
    puts("TIMER PASS cycles=0x");
    put_hex(timer_end - timer_start);
    putc('\n');
    mmio_write32(TIMER_COMPARE_LO, timer_end + 32u);
    mmio_write32(TIMER_CONTROL, 3u);

    if (mmio_read32(UNMAPPED_TEST_ADDR) != 0xdeadbeefu) {
        fail(0x04u);
    }
    debug_set(0x40u);
    puts("DEFAULT SLAVE PASS\n");
    debug_set(0x50u);
    apu_run_full_network();
    debug_set(0x60u);
    apu_run_zero_conv();
    debug_set(0x70u);
    apu_mmio_smoke();
    debug_set(0x7fu);
    puts("SOC PREBOARD PASS\n");

    mmio_write32(CONSOLE_EXIT, 0u);
    for (;;) {
    }
}
