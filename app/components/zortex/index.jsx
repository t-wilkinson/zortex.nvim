import { Articles } from "./articles";
import Page from "./Page";
export { defaultContent } from "./text";

export const Zortex = (props) => {
  return <div style={{width: "100vw", height: "100vh"}}>
    <Page />
    {/* <Articles {...props} /> */}
  </div>
}

export { Articles, Page };

export default Zortex;
