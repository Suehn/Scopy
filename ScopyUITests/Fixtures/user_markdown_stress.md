# H1：Markdown / 富文本 / 数学 / 表格 / Unicode / 边缘 Case 综合渲染测试

> 这不是一篇正常文章，而是一张尽量覆盖不同渲染路径的“压力测试页”。
> 有些语法属于标准 Markdown，有些属于 GitHub Flavored Markdown，有些属于 LaTeX，有些属于 HTML 扩展；不同 ChatGPT 客户端可能存在轻微差异。

---

## H2：1. 标题层级

# 一级标题 H1

## 二级标题 H2

### 三级标题 H3

#### 四级标题 H4

##### 五级标题 H5

###### 六级标题 H6

普通正文紧跟在六级标题后面。

---

## 2. 基础行内格式

普通文本。

**粗体 Bold**

*斜体 Italic*

***粗斜体 Bold + Italic***

~~删除线 Strikethrough~~

`inline code`

普通中文 + **粗体中文** + *斜体中文* + ~~删除中文~~ + `代码中文`

组合嵌套：

**粗体里面有 *斜体* 和 `code`**

*斜体里面有 **粗体***

***三个星号同时作用***

~~删除线中 **仍然可以粗体**~~

`代码中的 **星号不会成为粗体**`

连续标点测试：**粗体。**、*斜体！*、~~删除？~~。

英文边界：before**bold**after / before*italic*after / snake_case_identifier / `some_long_variable_name`.

---

## 3. 转义字符

这些应该显示为普通字符，而不是触发 Markdown：

*这不是斜体*

**这不是粗体**

# 这不是标题

- 这不是列表

> 这不是引用

`这不是代码语法`

反斜杠本身：\

星号：*

下划线：_

井号：#

左中括号：[

右中括号：]

括号：\( \)

大括号：{ }

表格竖线：|

---

## 4. 特殊字符与 Unicode

中文：天地玄黄，宇宙洪荒。

繁體中文：天地玄黃，宇宙洪荒。

English: The quick brown fox jumps over the lazy dog.

日本語：これは日本語の表示テストです。

한국어: 이것은 한국어 렌더링 테스트입니다.

العربية: مرحبًا بالعالم

עברית: שלום עולם

Ελληνικά: Καλημέρα κόσμε

Русский: Привет, мир

हिन्दी: नमस्ते दुनिया

ไทย: สวัสดีชาวโลก

Emoji：

😀 😃 😄 😅 😂 🤔 🫠 🫡 🥹 🤯 👀 🧠 🧪 🧬 🖥️ 💻 ⚙️ 🔬 🚀

组合 Emoji：

👨‍💻 👩‍🔬 👨‍👩‍👧‍👦 🏳️‍🌈 🏴‍☠️ ❤️‍🔥

肤色修饰：

👍 👍🏻 👍🏼 👍🏽 👍🏾 👍🏿

国旗：

🇨🇳 🇺🇸 🇯🇵 🇩🇪 🇫🇷 🇬🇧 🇨🇦 🇦🇺

数学 Unicode：

α β γ δ ε θ λ μ π σ φ ψ ω
Α Β Γ Δ Θ Λ Ξ Π Σ Φ Ψ Ω
∞ ≈ ≠ ≤ ≥ ± × ÷ ∑ ∏ ∫ ∂ ∇ √ ∝ ∈ ∉ ⊂ ⊆ ∪ ∩
ℕ ℤ ℚ ℝ ℂ

货币：

¥ ￥ $ € £ ₩ ₹ ₽ ₿

箭头：

← → ↑ ↓ ↔ ⇒ ⇔ ↦ ↗ ↘ ↙ ↖

框线：

┌──────┬──────┐
│ 左侧 │ 右侧 │
├──────┼──────┤
│  A   │  B   │
└──────┴──────┘

---

# 5. 段落、换行与分隔线

这是第一段。Markdown 中空一行通常会形成新段落。

这是第二段。

这一行末尾人为加入两个空格。
如果渲染器支持标准 Markdown hard break，这一行应直接换行。

而这里是普通的新段落。

---

三个连字符：

---

三个星号：

---

三个下划线：

---

---

# 6. 引用 Blockquote

> 一级引用。
>
> 引用可以包含多个段落。
>
> 还可以包含 **粗体**、*斜体*、`inline code` 和公式 \(E=mc^2\)。

嵌套引用：

> 第一层
>
> > 第二层
> >
> > > 第三层
> > >
> > > > 第四层
> > > >
> > > > > 第五层

引用中放列表：

> * Alpha
> * Beta
>
>   * Beta.1
>   * Beta.2
> * Gamma

引用中放代码：

> ```python
> def quoted_code():
>     return "inside blockquote"
> ```

---

# 7. 无序列表

* 第一项
* 第二项
* 第三项

  * 二级 A
  * 二级 B

    * 三级 B.1
    * 三级 B.2

      * 四级

        * 五级

          * 六级
* 回到一级

换一种 marker：

* 星号项目
* 星号项目

  * 嵌套项目

再一种：

* 加号项目
* 加号项目

---

# 8. 有序列表

1. 第一项
2. 第二项
3. 第三项

   1. 三级编号 1
   2. 三级编号 2

      1. 更深一级
      2. 再一个
4. 第四项

从非 1 开始：

7. Seven
8. Eight
9. Nine

Markdown 源码中即便全部写成 `1.`，很多渲染器仍会自动递增：

1. Apple
2. Banana
3. Cherry
4. Durian

混合：

1. 主任务

   * 子任务 A
   * 子任务 B
2. 第二任务

   1. 子步骤 1
   2. 子步骤 2

      * 注意事项
      * 另一个注意事项

---

# 9. Task List / Checklist

* [x] 已完成
* [ ] 未完成
* [x] Markdown
* [x] LaTeX
* [x] 表格
* [ ] 尚未发生的事项

  * [x] 子任务完成
  * [ ] 子任务未完成

这属于 GFM 扩展；不同渲染器可能显示为复选框，也可能仅显示字符。

---

# 10. 行内代码

变量：`x`

函数：`std::vector<int>`

Python：`result = [x**2 for x in xs]`

Shell：`rm -rf ./build`

SQL：`SELECT * FROM users WHERE id = 42;`

HTML：`<div class="container">hello</div>`

JSON：`{"name":"Alice","score":100}`

Markdown 源码：`**not bold because inside code**`

特殊内容：`a | b | c`

文件路径：`C:\Users\Alice\Documents\test.txt`

Unix 路径：`/usr/local/bin/python`

包含反引号本身的极端情况，可以用更长的反引号 delimiter：

`` `foo()` ``

---

# 11. 多行代码块

### Python

```python
from dataclasses import dataclass
from typing import Generic, TypeVar

T = TypeVar("T")

@dataclass
class Box(Generic[T]):
    value: T

def fibonacci(n: int) -> int:
    if n < 2:
        return n
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a

print(Box(fibonacci(20)))
```

### JavaScript / TypeScript

```typescript
type User = {
  id: number;
  name: string;
  tags: string[];
};

const users: User[] = [
  { id: 1, name: "Alice", tags: ["admin", "dev"] },
  { id: 2, name: "Bob", tags: ["user"] },
];

const names = users
  .filter(user => user.tags.includes("dev"))
  .map(({ name }) => name);

console.log(names);
```

### Rust

```rust
fn main() {
    let values = vec![1, 2, 3, 4, 5];

    let squares: Vec<i32> = values
        .iter()
        .map(|x| x * x)
        .collect();

    println!("{:?}", squares);
}
```

### C++

```cpp
#include <iostream>
#include <vector>
#include <numeric>

int main() {
    std::vector<int> xs{1, 2, 3, 4, 5};

    auto sum = std::accumulate(xs.begin(), xs.end(), 0);

    std::cout << "sum = " << sum << '\n';
}
```

### SQL

```sql
WITH ranked AS (
    SELECT
        user_id,
        score,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY created_at DESC
        ) AS rn
    FROM submissions
)
SELECT user_id, score
FROM ranked
WHERE rn = 1
ORDER BY score DESC;
```

### Bash

```bash
set -euo pipefail

for file in *.txt; do
    printf 'processing: %s\n' "$file"
    wc -l "$file"
done
```

### JSON

```json
{
  "name": "render-test",
  "version": 1,
  "features": {
    "markdown": true,
    "latex": true,
    "unicode": true
  },
  "values": [null, true, false, 0, 1.5, -42]
}
```

### YAML

```yaml
service:
  name: render-test
  replicas: 3
  enabled: true

features:
  - markdown
  - latex
  - tables
```

### TOML

```toml
[package]
name = "render-test"
version = "0.1.0"

[dependencies]
foo = "1.2.3"
```

### Diff

```diff
 def calculate(x):
-    return x * 2
+    return x * 3
```

---

# 12. 嵌套代码围栏 Edge Case

下面外层使用四个反引号，因此内部的三个反引号可以作为普通内容出现：

````markdown
```python
print("这里的三反引号没有结束外层代码块")
```

**这里也只是源码，不会粗体。**
````

---

# 13. 行内数学公式

最简单：

\(x + y = z\)

二次方程：

\(ax^2 + bx + c = 0\)

求根公式：

$$
x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}
$$

欧拉恒等式：

$$
e^{i\pi}+1=0
$$

质能方程：

$$
E = mc^2
$$

勾股定理：

$$
a^2+b^2=c^2
$$

---

# 14. 分数、根号、上下标

$$
\frac{1}{2}
+\frac{2}{3}
=\frac{7}{6}
$$

$$
\sqrt{x},\qquad
\sqrt[3]{x},\qquad
\sqrt{\frac{a+b}{c+d}}
$$

$$
x_i,\quad
x_{i,j},\quad
x^{2},\quad
x^{n+1},\quad
x_i^{(t+1)}
$$

$$
2^{2^{2^{2}}}
$$

---

# 15. 求和、连乘、积分、极限

$$
\sum_{i=1}^{n} i
=
\frac{n(n+1)}{2}
$$

$$
\prod_{k=1}^{n} k = n!
$$

$$
\int_0^1 x^2\,dx
=
\frac13
$$

$$
\int_{-\infty}^{+\infty}
e^{-x^2}\,dx
=
\sqrt{\pi}
$$

$$
\lim_{x\to 0}
\frac{\sin x}{x}
=
1
$$

$$
\lim_{n\to\infty}
\left(1+\frac1n\right)^n
=
e
$$

---

# 16. 多行公式

$$
\begin{aligned}
(a+b)^2
&= (a+b)(a+b) \\
&= a^2+ab+ba+b^2 \\
&= a^2+2ab+b^2.
\end{aligned}
$$

再来一个：

$$
\begin{aligned}
S_n
&= 1+2+\cdots+n \\
2S_n
&= (1+n)+(2+n-1)+\cdots \\
&= n(n+1) \\
S_n
&= \frac{n(n+1)}2.
\end{aligned}
$$

---

# 17. Piecewise / Cases

$$
f(x)=
\begin{cases}
x^2, & x\ge 0,\\
-x, & x<0.
\end{cases}
$$

更复杂：

$$
\operatorname{ReLU}(x)=
\begin{cases}
0,&x\le0,\\
x,&x>0.
\end{cases}
$$

$$
\operatorname{sign}(x)=
\begin{cases}
-1,&x<0,\\
0,&x=0,\\
1,&x>0.
\end{cases}
$$

---

# 18. 矩阵

二维矩阵：

$$
A=
\begin{bmatrix}
1&2\\
3&4
\end{bmatrix}
$$

三维：

$$
B=
\begin{pmatrix}
a&b&c\\
d&e&f\\
g&h&i
\end{pmatrix}
$$

行列式：

$$
\det(A)=
\begin{vmatrix}
a&b\\
c&d
\end{vmatrix}
=ad-bc
$$

增广矩阵：

$$
\left[
\begin{array}{ccc|c}
1&2&3&4\\
0&1&5&6\\
0&0&1&7
\end{array}
\right]
$$

---

# 19. 向量、线性代数

$$
\mathbf{x}
=
\begin{bmatrix}
x_1\\
x_2\\
\vdots\\
x_n
\end{bmatrix}
$$

$$
A\mathbf{x}=\mathbf{b}
$$

$$
A^{-1}A=I
$$

$$
A=Q\Lambda Q^{-1}
$$

$$
\|x\|_2
=
\sqrt{\sum_{i=1}^{n}x_i^2}
$$

$$
\langle x,y\rangle
=
x^\top y
$$

---

# 20. 概率与统计

条件概率：

$$
P(A\mid B)
=
\frac{P(A\cap B)}{P(B)}
$$

贝叶斯公式：

$$
P(A\mid B)
=
\frac{P(B\mid A)P(A)}
{P(B)}
$$

期望：

$$
\mathbb E[X]
=
\sum_x xP(X=x)
$$

方差：

$$
\operatorname{Var}(X)
=
\mathbb E[(X-\mu)^2]
=
\mathbb E[X^2]-\mathbb E[X]^2
$$

正态分布：

$$
f(x)
=
\frac{1}
{\sigma\sqrt{2\pi}}
\exp\left(
-\frac{(x-\mu)^2}{2\sigma^2}
\right)
$$

---

# 21. 微积分与偏导

$$
\frac{d}{dx}x^n=nx^{n-1}
$$

$$
\nabla f(x)
=
\begin{bmatrix}
\frac{\partial f}{\partial x_1}\\
\vdots\\
\frac{\partial f}{\partial x_n}
\end{bmatrix}
$$

Hessian：

$$
H_f(x)
=
\begin{bmatrix}
\frac{\partial^2f}{\partial x_1^2}
&
\frac{\partial^2f}{\partial x_1\partial x_2}
\\
\frac{\partial^2f}{\partial x_2\partial x_1}
&
\frac{\partial^2f}{\partial x_2^2}
\end{bmatrix}
$$

---

# 22. 机器学习公式

Softmax：

$$
p_i
=
\frac{e^{z_i}}
{\sum_{j=1}^{K}e^{z_j}}
$$

Cross-entropy：

$$
\mathcal L
=
-\sum_{i=1}^{K}y_i\log p_i
$$

Attention：

$$
\operatorname{Attention}(Q,K,V)
=
\operatorname{softmax}
\left(
\frac{QK^\top}{\sqrt{d_k}}
\right)V
$$

Scaled dot-product attention 逐元素写法：

$$
a_{ij}
=
\frac{
\exp\left(
q_i^\top k_j/\sqrt{d_k}
\right)
}{
\sum_{\ell=1}^{n}
\exp\left(
q_i^\top k_\ell/\sqrt{d_k}
\right)
}
$$

Transformer 残差：

$$
x_{\ell+1}
=
x_\ell+
F_\ell(x_\ell)
$$

梯度下降：

$$
\theta_{t+1}
=
\theta_t
-
\eta\nabla_\theta\mathcal L(\theta_t)
$$

Adam 的一部分：

$$
m_t
=
\beta_1m_{t-1}
+
(1-\beta_1)g_t
$$

$$
v_t
=
\beta_2v_{t-1}
+
(1-\beta_2)g_t^2
$$

---

# 23. 集合论与逻辑

$$
A\subseteq B
$$

$$
A\cap B,\qquad
A\cup B,\qquad
A\setminus B
$$

$$
x\in A,\qquad
x\notin A
$$

$$
\forall x\in\mathbb R,\quad
x^2\ge0
$$

$$
\exists x\in\mathbb R:
x^2=2
$$

$$
P\land Q,\qquad
P\lor Q,\qquad
\neg P,\qquad
P\Rightarrow Q,\qquad
P\Leftrightarrow Q
$$

---

# 24. 数学“异形”排版

$$
\boxed{
\displaystyle
\sum_{k=0}^{\infty}
\frac{x^k}{k!}
=
e^x
}
$$

$$
\underbrace{
1+1+\cdots+1
}_{n\text{ 个}}
=n
$$

$$
\overbrace{
a+b+c
}^{\text{group}}
$$

$$
\left(
\frac{
\left[
\sum_{i=1}^{n}
\left(x_i-\bar x\right)^2
\right]^{1/2}
}{
n-1
}
\right)
$$

---

# 25. 普通表格

| 姓名    | 年龄 | 城市 |    分数 |
| ----- | -: | -- | ----: |
| Alice | 20 | 北京 |  95.5 |
| Bob   | 21 | 上海 |  88.0 |
| Carol | 19 | 深圳 |   100 |
| Dave  | 22 | 杭州 | 73.25 |

---

# 26. 对齐表格

| 左对齐    |    居中    |    右对齐 |
| :----- | :------: | -----: |
| left   |  center  |    123 |
| 中文     |    中间    | 456.78 |
| `code` | **bold** |    -42 |

---

# 27. 单元格内混合格式

| 类型    | 示例          | 备注        |
| ----- | ----------- | --------- |
| 粗体    | **hello**   | Markdown  |
| 斜体    | *hello*     | Markdown  |
| 删除线   | ~~hello~~   | GFM       |
| 行内代码  | `foo()`     | monospace |
| 数学    | \(x^2+y^2\) | LaTeX     |
| 中文    | 测试内容        | CJK       |
| Emoji | 🧠🚀        | Unicode   |
| 转义竖线  | A | B       | 不应拆列      |

---

# 28. 含长文本的普通表格

| ID | 标题                                                                               | 描述                                                                                                                            |  状态 |
| -: | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | :-: |
|  1 | 短标题                                                                              | 简短描述。                                                                                                                         |  ✅  |
|  2 | 一个明显比其他标题长很多很多很多很多很多很多很多的标题                                                      | 这一格包含相当长的一段文本，用来测试客户端如何计算列宽、是否自动换行，以及在手机窄屏下究竟是横向滚动还是把内容压缩成多行。这里继续增加文本长度：ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 中文中文中文中文中文中文中文。 |  🟡 |
|  3 | `extremely_long_identifier_without_spaces_abcdefghijklmnopqrstuvwxyz_0123456789` | 无空格长 token 可能特别容易触发表格横向滚动。                                                                                                    |  ⚠️ |
|  4 | Mixed 混合                                                                         | **Bold**, *italic*, `code`, \(x^2\), Emoji 🧪                                                                                 |  ✅  |

---

# 29. 超宽表格：横向滚动压力测试

| C01 | C02 | C03 | C04 | C05 | C06 | C07 | C08 | C09 | C10 | C11 | C12 | C13 | C14 | C15 | C16 | C17 | C18 | C19 | C20 |
| --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
|   1 |   2 |   3 |   4 |   5 |   6 |   7 |   8 |   9 |  10 |  11 |  12 |  13 |  14 |  15 |  16 |  17 |  18 |  19 |  20 |
|  21 |  22 |  23 |  24 |  25 |  26 |  27 |  28 |  29 |  30 |  31 |  32 |  33 |  34 |  35 |  36 |  37 |  38 |  39 |  40 |
|  41 |  42 |  43 |  44 |  45 |  46 |  47 |  48 |  49 |  50 |  51 |  52 |  53 |  54 |  55 |  56 |  57 |  58 |  59 |  60 |
|  61 |  62 |  63 |  64 |  65 |  66 |  67 |  68 |  69 |  70 |  71 |  72 |  73 |  74 |  75 |  76 |  77 |  78 |  79 |  80 |
|  81 |  82 |  83 |  84 |  85 |  86 |  87 |  88 |  89 |  90 |  91 |  92 |  93 |  94 |  95 |  96 |  97 |  98 |  99 | 100 |

这个表在窄屏上尤其适合观察客户端是：

* 横向滚动；
* 强行压缩列宽；
* 自动折行；
* 还是重新布局。

---

# 30. 超长表格：纵向压力测试

| Row |    二进制 | 十六进制 |   平方 |    立方 |  奇偶 |
| --: | -----: | ---: | ---: | ----: | :-: |
|   1 |      1 | 0x01 |    1 |     1 |  奇  |
|   2 |     10 | 0x02 |    4 |     8 |  偶  |
|   3 |     11 | 0x03 |    9 |    27 |  奇  |
|   4 |    100 | 0x04 |   16 |    64 |  偶  |
|   5 |    101 | 0x05 |   25 |   125 |  奇  |
|   6 |    110 | 0x06 |   36 |   216 |  偶  |
|   7 |    111 | 0x07 |   49 |   343 |  奇  |
|   8 |   1000 | 0x08 |   64 |   512 |  偶  |
|   9 |   1001 | 0x09 |   81 |   729 |  奇  |
|  10 |   1010 | 0x0A |  100 |  1000 |  偶  |
|  11 |   1011 | 0x0B |  121 |  1331 |  奇  |
|  12 |   1100 | 0x0C |  144 |  1728 |  偶  |
|  13 |   1101 | 0x0D |  169 |  2197 |  奇  |
|  14 |   1110 | 0x0E |  196 |  2744 |  偶  |
|  15 |   1111 | 0x0F |  225 |  3375 |  奇  |
|  16 |  10000 | 0x10 |  256 |  4096 |  偶  |
|  17 |  10001 | 0x11 |  289 |  4913 |  奇  |
|  18 |  10010 | 0x12 |  324 |  5832 |  偶  |
|  19 |  10011 | 0x13 |  361 |  6859 |  奇  |
|  20 |  10100 | 0x14 |  400 |  8000 |  偶  |
|  21 |  10101 | 0x15 |  441 |  9261 |  奇  |
|  22 |  10110 | 0x16 |  484 | 10648 |  偶  |
|  23 |  10111 | 0x17 |  529 | 12167 |  奇  |
|  24 |  11000 | 0x18 |  576 | 13824 |  偶  |
|  25 |  11001 | 0x19 |  625 | 15625 |  奇  |
|  26 |  11010 | 0x1A |  676 | 17576 |  偶  |
|  27 |  11011 | 0x1B |  729 | 19683 |  奇  |
|  28 |  11100 | 0x1C |  784 | 21952 |  偶  |
|  29 |  11101 | 0x1D |  841 | 24389 |  奇  |
|  30 |  11110 | 0x1E |  900 | 27000 |  偶  |
|  31 |  11111 | 0x1F |  961 | 29791 |  奇  |
|  32 | 100000 | 0x20 | 1024 | 32768 |  偶  |

---

# 31. 表格 Edge Cases

### 空单元格

| A     | B     | C     |
| ----- | ----- | ----- |
| value |       | value |
|       | value |       |
|       |       |       |

### 只有一个字符

| A | B | C |
| - | - | - |
| x | y | z |
| 1 | 2 | 3 |

### 单元格含竖线

| 表达式            | 含义        |
| -------------- | --------- |
| `a \| b`       | 代码/文本中的竖线 |
| A | B          | 转义 pipe   |
| \(P(A\mid B)\) | 数学条件概率    |

### 单元格中包含 HTML 换行

| 项目 | 多行内容                   |
| -- | ---------------------- |
| A  | 第一行<br>第二行<br>第三行      |
| B  | Alpha<br>Beta<br>Gamma |

客户端是否执行 `<br>` 取决于渲染策略。

---

# 32. “异形表格”：ASCII 表

```text
┌────────────┬──────────────┬────────────┐
│ Component  │ State        │ Latency    │
├────────────┼──────────────┼────────────┤
│ Parser     │ READY        │   1.2 ms   │
│ Renderer   │ READY        │   3.8 ms   │
│ Formula    │ TESTING      │  12.4 ms   │
├────────────┼──────────────┼────────────┤
│ TOTAL      │              │  17.4 ms   │
└────────────┴──────────────┴────────────┘
```

Unicode 双线版：

```text
╔══════════════╦══════════════╦══════════════╗
║       X      ║       Y      ║       Z      ║
╠══════════════╬══════════════╬══════════════╣
║      123     ║      456     ║      789     ║
╠══════════════╬══════════════╬══════════════╣
║    中文测试   ║     Emoji    ║      🧠      ║
╚══════════════╩══════════════╩══════════════╝
```

---

# 33. “异形格式”：树结构

```text
project/
├── README.md
├── src/
│   ├── main.py
│   ├── parser.py
│   ├── renderer.py
│   └── utils/
│       ├── math.py
│       └── text.py
├── tests/
│   ├── test_parser.py
│   └── test_renderer.py
└── pyproject.toml
```

---

# 34. 时间线

```text
2026-08-27
    │
    ├── 09:00  Start
    │
    ├── 10:30  Parse Markdown
    │
    ├── 12:00  Test LaTeX
    │
    ├── 15:00  Test Tables
    │
    └── 18:00  Render Complete
```

---

# 35. 简单流程图：纯文本

```text
              ┌─────────────┐
              │ User Input  │
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │   Parser    │
              └──────┬──────┘
                     │
             ┌───────┴────────┐
             │                │
             ▼                ▼
       ┌──────────┐     ┌──────────┐
       │ Markdown │     │  LaTeX   │
       └─────┬────┘     └─────┬────┘
             │                │
             └───────┬────────┘
                     ▼
              ┌─────────────┐
              │  Renderer   │
              └─────────────┘
```

---

# 36. 状态机风格

```text
        +-------+
        | IDLE  |
        +---+---+
            |
          start
            |
            v
       +----+----+
       | RUNNING |
       +----+----+
        /       \
   success     failure
      /           \
     v             v
+---------+    +--------+
|  DONE   |    | ERROR  |
+---------+    +--------+
```

---

# 37. 箭头与逻辑关系

普通：

A → B → C → D

分叉：

```text
A
├──→ B
│    ├──→ D
│    └──→ E
└──→ C
     ├──→ F
     └──→ G
```

依赖：

$$
A\rightarrow B\rightarrow C
$$

$$
A
\Rightarrow
(B\land C)
\Rightarrow
D
$$

---

# 38. HTML 扩展语法测试

以下内容是否真正以 HTML 样式渲染，取决于客户端的 Markdown sanitizer。

<details>
<summary>点击尝试展开</summary>

这里是 `<details>` 内部。

**Markdown 是否继续解析**也取决于具体实现。

```text
hidden content
```

</details>

键盘键：

<kbd>Ctrl</kbd> + <kbd>C</kbd>

<kbd>⌘</kbd> + <kbd>Shift</kbd> + <kbd>P</kbd>

上标/下标：

H<sub>2</sub>O

E = mc<sup>2</sup>

高亮测试：

<mark>highlight / mark</mark>

删除 HTML：

<del>deleted via HTML</del>

---

# 39. Markdown 与 HTML 混排

**Markdown Bold**

<div>
HTML div 中的文本
</div>

*Markdown Italic*

如果 sanitizer 不允许某个 HTML 标签，它可能被删除、转义，或者按普通文本显示。

---

# 40. 空白字符 Edge Case

普通空格：

`A B`

多个普通空格在普通 Markdown 正文中往往会被折叠：

A     B     C

代码块中不会折叠：

```text
A     B          C
1     2          3
```

Tab / 缩进测试：

```text
Level 0
    Level 1
        Level 2
            Level 3
```

---

# 41. 超长单词 / 无断点 Token

普通英文长词：

pneumonoultramicroscopicsilicovolcanoconiosis

程序员版：

`aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`

URL 形态但只作为代码展示：

`https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`

长路径：

`/very/very/very/very/very/very/very/very/very/long/path/to/a/file/that/might/force/horizontal/scrolling/example.txt`

---

# 42. 连续标点压力测试

中文：

？！。，、；：“”‘’（）【】《》——……·

英文：

`!@#$%^&*()_+-=[]{};':",./<>?\|`

组合：

`a[b]{c}(d)<e>::f->g=>h&&i||j`

正则：

`^(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.+)$`

模板：

`${user.name ?? "anonymous"}`

---

# 43. Emoji 与文字基线

A😀B

A🧠B

A👨‍💻B

A❤️‍🔥B

中文😀中文

`code😀emoji`

**bold😀emoji**

\(x_{\text{😀}}\)

---

# 44. Combining Character / 看起来相同但编码不同

预组字符：

é

组合字符：

é

视觉上可能相同，但 Unicode 编码未必相同。

再例如：

Å

Å

这类字符对于文本搜索、字符串长度、光标定位、换行计算都可能是边缘 case。

---

# 45. Zero-width / 不可见字符概念示例

为了避免真的大量插入不可见字符导致阅读混乱，这里使用名称表示：

`ZERO WIDTH SPACE = U+200B`

`ZERO WIDTH JOINER = U+200D`

`NO-BREAK SPACE = U+00A0`

Emoji `👨‍💻` 本质上就使用了 Zero Width Joiner 把多个符号组合起来。

---

# 46. RTL / 双向文字

英语 + Arabic：

English مرحبا English

数字 + Arabic：

ABC 123 مرحبا 456 XYZ

Hebrew：

ABC שלום 123 XYZ

混入代码通常更容易触发双向文本边缘情况：

`const x = "مرحبا";`

`user_שלום_123`

---

# 47. 长引用

> 这是第一层引用。
>
> 它可以拥有多个段落，并且保持左侧引用线。
>
> > 第二层引用出现。
> >
> > 可以继续包含 `inline code`。
> >
> > > 第三层引用。
> > >
> > > $$
> > > x^2+y^2=z^2
> > > $$
> >
> > 回到第二层。
>
> 回到第一层。

---

# 48. 列表中嵌套引用与代码

1. 第一项

   > 第一项中的引用。
   >
   > 第二行。

2. 第二项

   ```python
   x = 1
   y = 2
   print(x + y)
   ```

3. 第三项

   * 子列表
   * 子列表

     * 更深层

       > 更深层的引用

---

# 49. 表格中数学公式

| 名称                | 公式                                             |            值 |   |     |
| ----------------- | ---------------------------------------------- | -----------: | - | --- |
| Euler             | \(e^{i\pi}+1=0\)                               |            0 |   |     |
| Pythagoras        | \(a^2+b^2=c^2\)                                |            — |   |     |
| Gaussian integral | \(\int_{-\infty}^{\infty}e^{-x^2}dx=\sqrt\pi\) | \(\sqrt\pi\) |   |     |
| Geometric series  | \(\sum_{k=0}^{\infty}r^k=\frac1{1-r}\)         |            ( | r | <1) |

---

# 50. 复杂公式：Transformer 一次压测

$$
\begin{aligned}
Q &= XW_Q,\\
K &= XW_K,\\
V &= XW_V,\\[4pt]
S &=
\frac{QK^\top}{\sqrt{d_k}},\\[4pt]
A &=
\operatorname{softmax}(S),\\[4pt]
O &= AV.
\end{aligned}
$$

Multi-head：

$$
\operatorname{MultiHead}(Q,K,V)
=
\operatorname{Concat}
(
\operatorname{head}_1,
\dots,
\operatorname{head}_h
)
W^O
$$

其中

$$
\operatorname{head}_i
=
\operatorname{Attention}
(
QW_i^Q,
KW_i^K,
VW_i^V
)
$$

---

# 51. 很大的矩阵

$$
M=
\begin{bmatrix}
a_{11}&a_{12}&a_{13}&\cdots&a_{1n}\\
a_{21}&a_{22}&a_{23}&\cdots&a_{2n}\\
a_{31}&a_{32}&a_{33}&\cdots&a_{3n}\\
\vdots&\vdots&\vdots&\ddots&\vdots\\
a_{m1}&a_{m2}&a_{m3}&\cdots&a_{mn}
\end{bmatrix}
$$

---

# 52. 深层括号尺寸测试

$$
\left[
\left\{
\left(
\frac{
1+\frac{
2+\frac{
3+\frac45
}{6}
}{7}
}{8}
\right)
\right\}
\right]
$$

---

# 53. 数学文字混排

$$
\text{如果 } x>0,\quad
\text{那么 } f(x)=x^2.
$$

$$
\operatorname{score}(x)
=
\underbrace{
\alpha\cdot\text{accuracy}
}_{\text{质量}}
-
\underbrace{
\beta\cdot\text{latency}
}_{\text{成本}}
$$

---

# 54. 代码中的“看起来像 Markdown”

```markdown
# 这里不会真的成为标题

**这里不会真的粗体**

> 这里不会真的成为引用

| A | B |
|---|---|
| 1 | 2 |

\[
x^2+y^2=z^2
\]
```

这是观察“语法高亮”和“Markdown 二次解析”边界的好测试。

---

# 55. Markdown 源码转义展示

下面这段代码，如果复制出去作为 Markdown：

```markdown
# Heading

**bold**

*italic*

~~deleted~~

`code`

> quote

- item 1
- item 2

1. ordered
2. ordered

| A | B |
|---|---|
| 1 | 2 |
```

---

# 56. 空代码块

下面理论上是一个空代码块：

```text
```

另一个只有空白：

```text
   
```

---

# 57. 空引用 / 极小结构

>

>

理论上不同渲染器对“完全空 blockquote”的处理可能不同。

极小表格：

| A |
| - |
| 1 |

---

# 58. Markdown 表格无法真正合并单元格

普通 Markdown 没有 `rowspan` / `colspan`。

所以这种结构：

```text
┌───────────────┬───────┐
│ 合并的大标题   │   C   │
├───────┬───────┼───────┤
│   A   │   B   │   D   │
└───────┴───────┴───────┘
```

用纯 Markdown table 通常无法忠实表达，只能依赖 HTML table；而 HTML table 又可能被客户端过滤。

---

# 59. 模拟“仪表盘”异形布局

```text
╭──────────────────────────────────────────────────────╮
│                  SYSTEM DASHBOARD                    │
├─────────────────┬─────────────────┬──────────────────┤
│ CPU             │ MEMORY          │ REQUESTS         │
│ ███████░░░ 72%  │ █████░░░░░ 51% │ 12,482 / min     │
├─────────────────┴─────────────────┴──────────────────┤
│ LATENCY                                              │
│ p50  18 ms    p95  41 ms    p99  113 ms             │
├──────────────────────────────────────────────────────┤
│ STATUS                                               │
│ Parser   ● OK                                        │
│ Math     ● OK                                        │
│ Tables   ● OK                                        │
╰──────────────────────────────────────────────────────╯
```

---

# 60. 文本进度条

```text
  0% [                                        ]
 10% [████                                    ]
 25% [██████████                              ]
 50% [████████████████████                    ]
 75% [██████████████████████████████          ]
100% [████████████████████████████████████████]
```

---

# 61. Sparklines / Unicode 小图

```text
▁▂▃▄▅▆▇█
█▇▆▅▄▃▂▁
▁▁▂▃▅█▅▃▂▁
```

数据：

```text
CPU:     ▁▂▂▃▄▃▅▆▇▆▅█
Memory:  ▂▂▃▃▄▄▄▅▅▅▆▆
Traffic: ▁▁▂▁▃▅▇█▆▄▂▁
```

---

# 62. Unicode 几何图形

○ ● ◉ ◎ ◌

□ ■ ▢ ▣ ▤ ▥ ▦ ▧ ▨ ▩

△ ▲ ▽ ▼ ◁ ◀ ▷ ▶

◇ ◆ ◈

★ ☆ ✦ ✧ ✪

状态：

`● ONLINE`

`○ OFFLINE`

`◐ PARTIAL`

`◉ ACTIVE`

---

# 63. “卡片”模拟

```text
┌──────────────────────────────┐
│ GPT Render Test              │
│                              │
│ Markdown      ✓              │
│ Mathematics   ✓              │
│ Tables        ✓              │
│ Code          ✓              │
│ Unicode       ✓              │
│                              │
│ Score: 98 / 100              │
└──────────────────────────────┘
```

---

# 64. 长 JSON / 结构化数据展示

```json
{
  "request": {
    "type": "render_stress_test",
    "languages": [
      "zh-CN",
      "en-US",
      "ja-JP",
      "ar",
      "he"
    ]
  },
  "markdown": {
    "headings": true,
    "bold": true,
    "italic": true,
    "strikethrough": true,
    "blockquote": true,
    "lists": {
      "ordered": true,
      "unordered": true,
      "tasks": true,
      "nested": true
    }
  },
  "math": {
    "inline": true,
    "display": true,
    "matrix": true,
    "aligned": true,
    "cases": true
  },
  "edgeCases": [
    "unicode",
    "emoji",
    "rtl",
    "very-long-token",
    "escaped-pipe",
    "nested-fence",
    "empty-cell"
  ]
}
```

---

# 65. 错误信息样式

```text
Error: failed to parse input
  at Parser.parse (parser.ts:42:17)
  at Renderer.render (renderer.ts:105:9)
  at main (index.ts:12:3)

Caused by:
  UnexpectedTokenError:
    expected: "]"
    received: "}"
```

---

# 66. Compiler-style Diagnostic

```text
error[E0308]: mismatched types
  --> src/main.rs:7:20
   |
 7 |     let x: i32 = "hello";
   |            ---   ^^^^^^^ expected `i32`, found `&str`
   |            |
   |            expected due to this
```

---

# 67. Git diff 样式

```diff
diff --git a/render.py b/render.py
index 1234567..abcdef0 100644
--- a/render.py
+++ b/render.py
@@ -1,5 +1,7 @@
 def render(text):
-    return text
+    parsed = parse_markdown(text)
+    html = render_ast(parsed)
+    return html
```

---

# 68. 日志格式

```text
2026-08-27T18:54:00.001-07:00 INFO  renderer starting
2026-08-27T18:54:00.017-07:00 DEBUG markdown parser initialized
2026-08-27T18:54:00.041-07:00 WARN  unsupported extension detected
2026-08-27T18:54:00.113-07:00 ERROR fallback renderer invoked
```

---

# 69. CSV

```csv
id,name,score,active
1,Alice,98.5,true
2,Bob,87.0,false
3,"Carol, Jr.",100,true
4,"Quote ""inside"" value",42,true
```

这里包含 CSV 的一个 edge case：字段中有逗号和双引号。

---

# 70. XML

```xml
<?xml version="1.0" encoding="UTF-8"?>
<root>
  <user id="42">
    <name>Alice &amp; Bob</name>
    <active>true</active>
  </user>
</root>
```

---

# 71. HTML 源码

```html
<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8">
    <title>Render Test</title>
  </head>
  <body>
    <main>
      <h1>Hello</h1>
      <p>世界</p>
    </main>
  </body>
</html>
```

---

# 72. CSS

```css
.card {
  display: grid;
  grid-template-columns: 1fr 2fr;
  gap: 1rem;
}

.card:hover {
  transform: translateY(-2px);
}

@media (max-width: 640px) {
  .card {
    grid-template-columns: 1fr;
  }
}
```

---

# 73. Regex

```regex
^(?<protocol>https?):\/\/
(?<host>[A-Za-z0-9.-]+)
(?::(?<port>\d+))?
(?<path>\/[^\s]*)?$
```

---

# 74. SQL + 数学语义混合

```sql
SELECT
    user_id,
    AVG(score) AS mean_score,
    STDDEV_POP(score) AS sigma
FROM observations
GROUP BY user_id
HAVING COUNT(*) >= 10;
```

对应数学：

$$
\mu
=
\frac1n
\sum_{i=1}^{n}x_i
$$

$$
\sigma
=
\sqrt{
\frac1n
\sum_{i=1}^{n}
(x_i-\mu)^2
}
$$

---

# 75. 标题中包含行内代码

### 使用 `malloc()` 的注意事项

### \(O(n\log n)\) 排序算法

### **粗体标题内容**

### Emoji 🧠 标题

---

# 76. 连续标题不插正文

## A

### B

#### C

##### D

###### E

正文。

---

# 77. 很长标题压力测试

## 这是一个故意写得非常非常非常非常非常非常非常非常非常非常非常非常非常非常非常长的标题，用来观察移动端自动换行、标题行高、粗体字重以及中英文数字混排 ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 的表现

正文恢复正常。

---

# 78. 数字格式

整数：

`0`, `1`, `-1`, `2147483647`, `9223372036854775807`

浮点：

`0.0`, `-0.0`, `1e-9`, `6.02214076e23`

特殊：

`NaN`, `Infinity`, `-Infinity`

带分隔：

1,000

1,000,000

1_000_000

百分数：

0%

50%

99.999%

100%

---

# 79. 真假值 / Null

`true`

`false`

`null`

`None`

`nil`

`undefined`

`NULL`

语义相近，但属于不同语言/协议。

---

# 80. 文件路径与命令

Windows：

`C:\Program Files\Example App\bin\example.exe`

Unix：

`/opt/example/bin/example`

相对路径：

`../../src/components/Button.tsx`

隐藏文件：

`.gitignore`

特殊 shell 名称：

`file with spaces.txt`

---

# 81. 引号

ASCII：

"double quote"

'single quote'

中文：

“中文双引号”

‘中文单引号’

法式：

« guillemets »

德式：

„Deutsch“

---

# 82. 省略号与破折号

三个点：...

Unicode 省略号：…

双省略号：……

Hyphen: -

En dash: –

Em dash: —

中文破折号：——

Minus：

$$
-1
$$

这里视觉相近，但实际上是不同字符。

---

# 83. Markdown 容易误判的下划线

普通 identifier：

`snake_case_variable`

正文：

snake_case_variable

强调尝试：

*this is italic*

双下划线：

**this may be bold**

程序标识符：

`__init__`

`std::enable_if_t`

---

# 84. 星号密集测试

*

**

---

---

---

源码视角：

```text
*
**
***
****
*****
```

实际单独放置星号时，有些组合可能被解释为分隔线或强调标记，所以这种边缘情况最好通过源码块检查。

---

# 85. 数学公式和标点

行内：\(f(x)=x^2\)，这是中文句子。

行内：\(P(A\mid B)=0.5\)。下一句。

Display math：

$$
x=42.
$$

公式本身带句号与公式外句号的视觉效果可能不同。

---

# 86. 长公式压力测试

$$
\mathcal{L}(\theta)
=
-\frac{1}{N}
\sum_{i=1}^{N}
\sum_{c=1}^{C}
y_{ic}
\log
\left(
\frac{
\exp\left(
z_c(x_i;\theta)/\tau
\right)
}{
\sum_{j=1}^{C}
\exp\left(
z_j(x_i;\theta)/\tau
\right)
}
\right)
+
\lambda
\sum_{k=1}^{K}
\left\|
W_k
\right\|_F^2
$$

这类公式主要测试横向 overflow、缩放与换行策略。

---

# 87. 公式中的字体

$$
ABC
$$

$$
\mathrm{ABC}
$$

$$
\mathbf{ABC}
$$

$$
\mathit{ABC}
$$

$$
\mathcal{ABC}
$$

$$
\mathbb{R}
$$

$$
\mathfrak{g}
$$

---

# 88. 常见算法复杂度

| 算法            |                 平均 |             最坏 |            空间 |
| ------------- | -----------------: | -------------: | ------------: |
| Binary Search |      \(O(\log n)\) |  \(O(\log n)\) |      \(O(1)\) |
| Merge Sort    |     \(O(n\log n)\) | \(O(n\log n)\) |      \(O(n)\) |
| Quick Sort    |     \(O(n\log n)\) |     \(O(n^2)\) | \(O(\log n)\) |
| Hash Lookup   |           \(O(1)\) |       \(O(n)\) |      \(O(n)\) |
| BFS           |         \(O(V+E)\) |     \(O(V+E)\) |      \(O(V)\) |
| Dijkstra      | \(O((V+E)\log V)\) |             同左 |    \(O(V+E)\) |

---

# 89. 真值表

| \(P\) | \(Q\) | \(P\land Q\) | \(P\lor Q\) | \(P\Rightarrow Q\) |
| :---: | :---: | :----------: | :---------: | :----------------: |
|   F   |   F   |       F      |      F      |          T         |
|   F   |   T   |       F      |      T      |          T         |
|   T   |   F   |       F      |      T      |          F         |
|   T   |   T   |       T      |      T      |          T         |

---

# 90. 二进制布局

```text
Byte:
┌───┬───┬───┬───┬───┬───┬───┬───┐
│ 7 │ 6 │ 5 │ 4 │ 3 │ 2 │ 1 │ 0 │
├───┼───┼───┼───┼───┼───┼───┼───┤
│ 1 │ 0 │ 1 │ 1 │ 0 │ 1 │ 0 │ 1 │
└───┴───┴───┴───┴───┴───┴───┴───┘

0b10110101 = 0xB5 = 181
```

---

# 91. Memory Layout 模拟

```text
Low Address
    │
    ▼
+------------------+
|      .text       |
+------------------+
|      .data       |
+------------------+
|       heap       |
|        ↓         |
|                  |
|        ↑         |
|       stack      |
+------------------+
    ▲
    │
High Address
```

---

# 92. HTTP 文本

```http
POST /api/v1/render HTTP/1.1
Host: example.invalid
Content-Type: application/json
Accept: application/json

{
  "markdown": "**hello**",
  "math": "x^2"
}
```

---

# 93. Unicode 边框嵌套

```text
╔══════════════════════════════════════════╗
║ Outer                                    ║
║  ┌────────────────────────────────────┐  ║
║  │ Middle                             │  ║
║  │   ╭────────────────────────────╮   │  ║
║  │   │ Inner                      │   │  ║
║  │   ╰────────────────────────────╯   │  ║
║  └────────────────────────────────────┘  ║
╚══════════════════════════════════════════╝
```

---

# 94. Markdown “相邻结构”测试

**bold**
`code`
*italic*
~~strike~~

> quote

* list

$$
x=1
$$

| A | B |
| - | - |
| 1 | 2 |

```text
code
```

以上故意让不同 block 类型相邻，用于观察 margin collapse / block spacing。

---

# 95. 重复相同字符

```text
============================================================
------------------------------------------------------------
____________________________________________________________
************************************************************
############################################################
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
```

---

# 96. 一个“接近实际回答”的复杂混排示例

假设我们分析一个长度为 \(n\) 的数组，并选择排序算法：

> 若数据规模较小，常数项可能比渐进复杂度更重要；若 \(n\) 很大，\(O(n\log n)\) 与 \(O(n^2)\) 的差距会迅速扩大。

设：

$$
n=10^6
$$

理论比较：

$$
n\log_2 n
\approx
10^6\times19.93
\approx
1.993\times10^7
$$

而：

$$
n^2=10^{12}
$$

| 算法         |             理论复杂度 |  稳定 |  原地 | 备注                |
| ---------- | ----------------: | :-: | :-: | ----------------- |
| Merge Sort |    \(O(n\log n)\) |  ✅  |  ❌  | 额外空间              |
| Heap Sort  |    \(O(n\log n)\) |  ❌  |  ✅  | cache locality 一般 |
| Quick Sort | 平均 \(O(n\log n)\) |  ❌  |  ✅  | 实际常常很快            |

伪代码：

```python
def sort(xs):
    if len(xs) <= 1:
        return xs

    pivot = xs[len(xs) // 2]
    left  = [x for x in xs if x < pivot]
    equal = [x for x in xs if x == pivot]
    right = [x for x in xs if x > pivot]

    return sort(left) + equal + sort(right)
```

结论中的重点可以用 **粗体**，术语可以用 `inline code`，数学关系放在 \(\LaTeX\) 中，而大量数据更适合表格。

---

# 97. 极深嵌套结构

* L1

  * L2

    * L3

      * L4

        * L5

          * L6

            * L7

              * L8

                * L9

                  * L10

大多数 UI 不会无限增加左侧缩进，达到一定深度后可读性会明显恶化。

---

# 98. 超长中文连续字符串

下面没有标点和空格，专门测试 CJK 自动断行：

天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光果珍李柰菜重芥姜海咸河淡鳞潜羽翔龙师火帝鸟官人皇始制文字乃服衣裳推位让国有虞陶唐吊民伐罪周发殷汤坐朝问道垂拱平章爱育黎首臣伏戎羌遐迩一体率宾归王。

---

# 99. 中英文数字代码混排

在 `TransformerBlock.forward()` 中，输入张量 \(X\in\mathbb R^{B\times T\times D}\)，经过 **LayerNorm → Multi-Head Attention → Residual Connection** 后仍保持 shape `B × T × D`；如果 `B=32`、`T=4096`、`D=4096`，仅一个 FP16 activation tensor 的理论原始大小就是

$$
32\times4096\times4096\times2
=
1{,}073{,}741{,}824
\text{ bytes}
\approx
1\text{ GiB}.
$$

这类段落同时压测 CJK、Latin、inline code、粗体和公式的 baseline/line-height。

---

# 100. 最后一个综合 Edge Case

> ### 引用里的标题
>
> **粗体**、*斜体*、~~删除线~~、`code`
>
> 1. 有序列表
>
>    * 无序列表
>
>      * [x] Task
>
> $$
> A=
> \begin{bmatrix}
> 1&2\\
> 3&4
> \end{bmatrix},
> \qquad
> \det(A)=-2
> $$
>
> | Key     | Value            |
> | ------- | ---------------- |
> | Unicode | 中文 🧠 α          |
> | Code    | `a \| b`         |
> | Math    | \(e^{i\pi}+1=0\) |
>
> ```python
> print("nested rendering test")
> ```

---

## 101. 哪些东西在回答里通常“不是普通 Markdown”

为了区分渲染层，可以把 ChatGPT 回答大致看成几类内容：

| 类型             | 典型表现           | 是否属于普通 Markdown |
| -------------- | -------------- | :-------------: |
| 标题、粗体、列表       | 文本排版           |        ✅        |
| Markdown table | 网格表格           |     ✅ / GFM     |
| fenced code    | 语法高亮代码块        |        ✅        |
| LaTeX          | 专门数学渲染         |      ❌，是扩展      |
| 文件附件卡片         | 可下载 artifact   |        ❌        |
| 图片             | 图片组件           |        ❌        |
| 地图、天气等交互组件     | Rich UI        |        ❌        |
| 引用 / 来源卡片      | 特殊引用 UI        |        ❌        |
| 写作块            | 可编辑/复制的专用内容块   |        ❌        |
| 普通 ASCII 图     | 本质是 code block |        ✅        |

---

## 102. 一个非常容易观察渲染器差异的“小型基准”

**A. Markdown**

> `code` **bold** *italic* ~~strike~~

**B. Math**

$$
\sum_{i=1}^{n}i=\frac{n(n+1)}2
$$

**C. Table**

| A        | B        | C       |
| -------- | -------- | ------- |
| 中文       | `code`   | \(x^2\) |
| Emoji 🧠 | **bold** | ~~old~~ |

**D. Code**

```python
print("Hello, 世界 🧠")
```

**E. Unicode**

`é ≠ é`，`👨‍💻`，`مرحبا`，`שלום`

**F. Overflow**

`aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`

---

## 103. 这次刻意覆盖到的主要渲染边界

* 6 级标题、段落、硬换行、水平分隔线。
* 粗体、斜体、粗斜体、删除线、inline code、转义。
* 无序/有序/任务列表以及多层嵌套。
* 多层 blockquote，并在引用中嵌套公式、表格、列表、代码。
* 多语言 fenced code 与四反引号嵌套 fence。
* 行内 / 块级 LaTeX、矩阵、cases、aligned、积分、极限、概率、集合、Transformer 公式。
* 普通表格、对齐表格、长表格、超宽表格、空 cell、escaped pipe、HTML `<br>`。
* ASCII/Unicode 树、流程图、仪表盘、内存布局、进度条等“非表格型结构”。
* CJK、RTL、Emoji、ZWJ、combining characters、特殊数学字符。
* 无空格超长 token、超长标题、连续标点、路径、正则等 overflow case。
* HTML `<details>` / `<kbd>` / `<sub>` / `<sup>` / `<mark>` 等可能被客户端 sanitizer 特殊处理的扩展语法。
* Markdown 看起来像 Markdown、但被代码 fence 阻止二次解析的情况。

其中最值得在 **桌面端 vs 手机端** 对比观察的是：**超宽表格、长公式、无断点 token、多层嵌套列表、RTL/CJK 混排、`<details>` 等 HTML 扩展**。这些最容易暴露客户端之间实际的布局差异。
