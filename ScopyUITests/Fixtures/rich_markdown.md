# 一级标题 `# H1`

## 二级标题 `## H2`

### 三级标题 `### H3`

#### 四级标题 `#### H4`

##### 五级标题 `##### H5`

###### 六级标题 `###### H6`

**粗体**、*斜体*、***粗斜体***、~~删除线~~、`行内代码`、<u>下划线（HTML）</u>

> 一级引用
>
> > 二级引用
> >
> > - 引用中的无序列表
> > - **强调**
> >
> > 1. 引用中的有序列表
> > 2. `code`
>
> 引用结束。

------

- 无序列表项 A
- 无序列表项 B
  - 缩进子项 B.1
  - 缩进子项 B.2
    - 更深层子项

* 星号列表项
* 另一个星号列表项

+ 加号列表项
+ 另一个加号列表项

1. 有序列表 1
2. 有序列表 2
   1. 嵌套有序列表 2.1
   2. 嵌套有序列表 2.2

- [x] 已完成任务
- [ ] 未完成任务
- [ ] 待办事项包含 **粗体** 与 [链接](https://example.com)

这是一个段落，其中包含自动链接：https://example.com，邮箱：user@example.com，以及一个带标题的链接：[OpenAI](https://openai.com "OpenAI")。

这是一个参考式链接：[参考链接][ref-link]，也是一个参考式图片：

![内联图片][inline-image]

| 左对齐 | 居中对齐 | 右对齐 |
| :----- | :------: | -----: |
| 单元格 `A1` | **B1** | 100 |
| 单元格 *A2* | ~~B2~~ | 200 |
| [链接](https://example.com) |  | `C3` |

这是脚注示例[^1]，这里再引用一次脚注[^2]。

这是一个行尾有两个空格的换行。  
这是换行后的下一行。

下面是分割线的另一种写法：

------

再来一种：

------

这是转义字符示例：\*不是斜体\*、\#不是标题、\$不是数学\$、\`不是代码\`

行内 HTML：<kbd>Ctrl</kbd> + <kbd>K</kbd>，<mark>高亮（HTML）</mark>，<sub>sub</sub>，<sup>sup</sup>

<details open>
<summary>点击展开</summary>

这里是可折叠内容，包含：

- 列表
- `代码`
- **强调**

</details>

```python
def hello(name: str) -> str:
    return f"Hello, {name}!"
```

```bash
echo "Markdown fenced code block"
```

    这是一个缩进代码块
    保留前导空格
    也属于 Markdown 语法的一部分

术语
: 定义列表写法（扩展语法）

另一个术语
: 第一条定义
: 第二条定义

- [链接到标题](#一级标题-h1)
- [跳转到脚注](#fn1)

<!-- 这是 HTML 注释，通常不会显示 -->

`$E=mc^2$` 与块级数学（扩展语法）：

$$
\int_0^1 x^2 \, dx = \frac{1}{3}
$$

| Syntax | Description |
| ------ | ----------- |
| Header | Title |
| Paragraph | Text |

[^1]: 这是一个简短脚注。
[^2]: 这是一个较长的脚注，里面可以包含 **Markdown**、`code`，甚至多行内容。

[ref-link]: https://example.com
[inline-image]: data:image/gif;base64,R0lGODlhAQABAIABAP///wAAACwAAAAAAQABAAACAkQBADs=
