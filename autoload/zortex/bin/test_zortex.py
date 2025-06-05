from zortex import file_to_zortex


def source_zettels():
    files = [
        """@@One
@Tag1
@Tag2

- Context
    - Thought 1
    - Thought 2
    - Thought 3
""",
        """@@Two
@Tag1
@Tag3

- Context
    - Thought 1
    - Thought 3
""",
        """@@Three
@Tag2

- Context 2
    - Thought 2
    - Thought 3
""",
    ]
    return map(file_to_zortex, files)
