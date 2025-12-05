#include <stdio.h>

int main() {
    int sum = 0;
    for (int i = 1; i <= 100000; ++i) {
        sum += i;
    }
    printf("Final sum = %lld (expected 705082704)\n", (long long)sum);
    return 0;
}