// Copyright 2026 Sonny Guardian
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt
//
// Regression test: the interval square root of a point interval must enclose
// the true square root. Both ends are checked exactly: for a candidate end r,
// the sign of fma(r, r, -x) is the sign of the exact value r*r - x (one
// correct rounding cannot change the sign of a nonzero result, and the
// corpus stays far from the underflow range).
//
// Built by the test suite with -frounding-math (see Jamfile.v2 / CMakeLists.txt).
// Control: add -DCONTROL_EXACT_POLICY to run the same checks on the exact
// (non-rounding) policy. The control must FAIL; if it passes, the test
// cannot see a narrowed interval.
#include <boost/numeric/interval.hpp>
#include <boost/core/lightweight_test.hpp>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

using namespace boost::numeric;
using namespace boost::numeric::interval_lib;

#if defined(CONTROL_EXACT_POLICY)
typedef interval<double, policies<save_state<rounded_arith_exact<double> >,
                                  checking_base<double> > > I;
#elif defined(TEST_STD_POLICY)
typedef interval<double, policies<save_state<rounded_arith_std<double> >,
                                  checking_base<double> > > I;
#else
typedef interval<double> I;  // default policy: save_state<rounded_arith_opp<double> >
#endif

// Inputs are read through volatile storage so nothing is folded at build time.
static volatile double corpus[96];
static int corpus_size = 0;

static void fill_corpus() {
  const double fixed[] = {3.0, 2.0, 5.0, 7.0, 10.0, 0.3, 1.5, 1e10 + 1.0,
                          123456.789, 0.7, 4.0, 9.0, 2.25, 1.0};
  for (double v : fixed) corpus[corpus_size++] = v;
  std::uint64_t s = 0x9e3779b97f4a7c15ULL;  // fixed seed
  while (corpus_size < 96) {
    s = s * 6364136223846793005ULL + 1442695040888963407ULL;
    std::uint64_t m = (s >> 12) | 0x3ff0000000000000ULL;  // [1, 2)
    double v; std::memcpy(&v, &m, 8);
    corpus[corpus_size++] = (s & 1) ? v * 2.0 : v;           // [1, 4)
  }
}

// Sign of r*r - x, exact.
static int sign_sq_minus(double r, double x) {
  double e = std::fma(r, r, -x);
  return (e > 0) - (e < 0);
}

int main() {
  fill_corpus();
  int misses = 0;
  for (int i = 0; i < corpus_size; ++i) {
    double x = corpus[i];
    std::fesetround(FE_TONEAREST);
    I y = sqrt(I(x));
    double lo = y.lower(), hi = y.upper();
    bool lo_ok = sign_sq_minus(lo, x) <= 0;
    bool hi_ok = sign_sq_minus(hi, x) >= 0;
    if (!lo_ok || !hi_ok) {
      ++misses;
      std::uint64_t bx, bl, bh;
      std::memcpy(&bx, &x, 8); std::memcpy(&bl, &lo, 8); std::memcpy(&bh, &hi, 8);
      std::printf("miss input=%016llx lower=%016llx upper=%016llx side=%s\n",
                  (unsigned long long)bx, (unsigned long long)bl,
                  (unsigned long long)bh, !hi_ok ? "upper" : "lower");
    }
    BOOST_TEST(lo_ok);
    BOOST_TEST(hi_ok);
  }
  std::printf("inputs=%d misses=%d\n", corpus_size, misses);
  return boost::report_errors();
}
