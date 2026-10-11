import React, { createContext, createRef, useMemo, useRef, useState, useContext, useLayoutEffect, forwardRef, useEffect } from 'react';
import * as THREE from 'three';
import { QuadraticBezierLine, Line, FlyControls, OrbitControls, Html, Text } from '@react-three/drei';
import { Canvas, useLoader, extend, useFrame, useThree } from '@react-three/fiber';
import WordTree2D from './WordTree2D';
import { defaultContent, parseTextToTree } from './text';
import StructurePage from './StructurePage';
import Node from './StructurePage'

export const Page = ({text=defaultContent}) => {
  const [[a, b, c, d, e]] = useState(() => [...Array(5)].map(createRef))
  const tree = parseTextToTree(text)

  return (
    <Canvas orthographic camera={{ zoom: 80, /* position: [0, 0, 100] */ }}>
  <StructurePage />
      {/* <WordTree2D tree={tree} /> */}
      {/* <Nodes> */}
      {/*   <Node ref={a} name="a" color="#204090" position={[-2, 2, 0]} connectedTo={[b, c, e]} /> */}
      {/*   <Node ref={b} name="b" color="#904020" position={[2, -3, 0]} connectedTo={[d, a]} /> */}
      {/*   <Node ref={c} name="c" color="#209040" position={[-0.25, 0, 0]} /> */}
      {/*   <Node ref={d} name="d" color="#204090" position={[0.5, -0.75, 0]} /> */}
      {/*   <Node ref={e} name="e" color="#204090" position={[-0.5, -1, 0]} /> */}
      {/* </Nodes> */}
    </Canvas>
  )
}

export default Page
