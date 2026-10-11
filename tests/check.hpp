#pragma once
// Tiny assertion helper that, unlike assert(), stays active in Release builds.
#include <cstdio>
#include <cstdlib>

namespace dharani_test {
inline int& failures() {
  static int n = 0;
  return n;
}
}  // namespace dharani_test

#define CHECK(cond)                                                                   \
  do {                                                                                \
    if (!(cond)) {                                                                    \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);   \
      ++dharani_test::failures();                                                     \
    }                                                                                 \
  } while (0)

#define CHECK_EQ(a, b) CHECK((a) == (b))
#define CHECK_NEAR(a, b, tol) CHECK(std::fabs((a) - (b)) <= (tol))

#define TEST_MAIN_END() \
  return dharani_test::failures() == 0 ? (std::puts("PASS"), 0) : (std::puts("FAIL"), 1)
