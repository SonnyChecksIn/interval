// Copyright 2026 Sonny Guardian
// Distributed under the Boost Software License, Version 1.0.
// Diagnostic only. State reads and separate calls can change optimization.
// The separate, unchanged sqrt_point.cpp is the enclosure regression test.
#if !defined(_WIN32) || !defined(_M_IX86) || defined(_WIN64)
# error This probe requires a native Windows x86 compiler target.
#endif
#include <boost/numeric/interval.hpp>
#include <cmath>
#include <cstdio>
#include <float.h>
#include <xmmintrin.h>

typedef char require_32_bit_pointer[(sizeof(void*) == 4) ? 1 : -1];
struct fp_state { unsigned short x87; unsigned int mxcsr; };

static __declspec(noinline) fp_state read_state() {
  unsigned short cw;
  __asm { fnstcw cw }
  fp_state s;
  s.x87 = cw;
  s.mxcsr = _mm_getcsr();
  return s;
}

static void restore_state(const fp_state& s) {
  unsigned short cw = s.x87;
  __asm { fldcw cw }
  _mm_setcsr(s.mxcsr);
}

static void print_call(const char* tag, double x, const fp_state& before,
                       const fp_state& after, double lo, double hi) {
  std::printf("call=%s input=%.17g before_x87=0x%04x before_mxcsr=0x%08x "
              "after_x87=0x%04x after_mxcsr=0x%08x lower=%.17g upper=%.17g\n",
              tag, x, static_cast<unsigned int>(before.x87), before.mxcsr,
              static_cast<unsigned int>(after.x87), after.mxcsr, lo, hi);
}

int main() {
  typedef boost::numeric::interval<double> interval_type;
  typedef boost::numeric::interval_lib::rounding_control<double> control;
  const fp_state process_entry = read_state();
  const double inputs[] = {3.0, 2.4920620415359735, 0.3, 4.0};
  int restore_errors = 0;
  std::printf("pointer_bytes=%u msc_ver=%d cplusplus=%ld\n",
              static_cast<unsigned int>(sizeof(void*)), _MSC_VER,
              static_cast<long>(__cplusplus));
  for (int i = 0; i < 4; ++i) {
    volatile double stored_input = inputs[i];
    const double x = stored_input;
    restore_state(process_entry);
    _control87(_RC_NEAR, _MCW_RC);
    const fp_state entry = read_state();

    control::downward();
    const fp_state down_before = read_state();
    volatile double down = std::sqrt(x);
    const fp_state down_after = read_state();

    control::upward();
    const fp_state up_before = read_state();
    volatile double up = std::sqrt(x);
    const fp_state up_after = read_state();

    restore_state(entry);
    const fp_state interval_before = read_state();
    const interval_type y = boost::numeric::sqrt(interval_type(x));
    const fp_state interval_after = read_state();
    const bool restored = ((entry.x87 ^ interval_after.x87) & 0x0f00) == 0 &&
                          ((entry.mxcsr ^ interval_after.mxcsr) & 0x6000) == 0;
    if (!restored) ++restore_errors;
    restore_state(entry);
    print_call("crt-down", x, down_before, down_after, down, down);
    print_call("crt-up", x, up_before, up_after, up, up);
    print_call("interval-point", x, interval_before, interval_after,
               y.lower(), y.upper());
    std::printf("entry_control_restored=%d\n", restored ? 1 : 0);
  }
  restore_state(process_entry);
  std::printf("probe_inputs=4 restore_errors=%d\n", restore_errors);
  return restore_errors == 0 ? 0 : 2;
}
