/// <reference types="node" />
import childProcess from 'child_process';
export default function opener(args: string | string[], tool: string | undefined): childProcess.ChildProcessWithoutNullStreams;
