#define _GNU_SOURCE
#include <sys/prctl.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == -1) {
        perror("prctl");
        return 1;
    }
    return 0;
}