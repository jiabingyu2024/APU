#include <memory>

#include "Vtb_top.h"
#include "verilated.h"

int main(int argc, char** argv) {
    auto context = std::make_unique<VerilatedContext>();
    context->commandArgs(argc, argv);
    context->traceEverOn(true);

    auto top = std::make_unique<Vtb_top>(context.get());
    while (!context->gotFinish()) {
        top->eval();
        if (!top->eventsPending()) {
            break;
        }
        context->time(top->nextTimeSlot());
    }

    top->final();
    return context->gotFinish() ? 0 : 1;
}
