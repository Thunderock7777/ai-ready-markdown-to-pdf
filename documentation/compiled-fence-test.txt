```yaml
title: "C, C++, and Java Code Fence Verification"
author: "Antigravity Test Harness"
date: "2026-11-07"
page-layout: default
title-rule: true
```

# Executable Code Fences Test

This document exercises C, C++, and Java code fences according to universal fence attribute rules.

## 1. Syntax-Highlighted Code Listings (run=false)

These code blocks have `run=false` and must be rendered as clean syntax-highlighted source blocks without execution prompts.

```c run=false
#include <stdio.h>

int main(void) {
    printf("Listing test: C code\n");
    return 0;
}
```

```cpp run=false
#include <iostream>
#include <vector>

int main() {
    std::vector<int> numbers = {1, 2, 3, 4, 5};
    for (int n : numbers) {
        std::cout << n << " ";
    }
    std::cout << "\n";
    return 0;
}
```

```java run=false
public class TestListing {
    public static void main(String[] args) {
        System.out.println("Listing test: Java code");
    }
}
```

## 2. Java Code Execution Test

Java execution uses the system `java` runner.

```java trusted=true
public class HelloWorld {
    public static void main(String[] args) {
        System.out.println("Hello from Java execution test!");
    }
}
```

## 3. C Code Snippet (trusted=true)

Snippet without explicit `main` is wrapped inside standard headers and `int main`.

```c trusted=true
printf("Hello from C snippet!\n");
```

## 4. C++ Code Snippet (trusted=true)

C++ snippet without explicit `main` is wrapped inside standard headers and `int main`.

```cpp trusted=true
std::cout << "Hello from C++ snippet!" << std::endl;
```
