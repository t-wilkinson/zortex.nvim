(self.webpackChunk_N_E=self.webpackChunk_N_E||[]).push([[749],{4169:function(e,n,t){(window.__NEXT_P=window.__NEXT_P||[]).push(["/buffer",function(){return t(2752)}])},2752:function(e,n,t){"use strict";t.r(n),t.d(n,{default:function(){return y}});var o=t(9722),i=t(169),c=t(2050),r=t(4246),u=t(7378),l=t(9923),s=t.n(l),a=t(173);function f(e){[document.body,document.documentElement].forEach((function(n){TweenLite.to(n,.4,{scrollTop:e,ease:Power2.easeOut})}))}function d(e){return'[data-source-line="'.concat(e,'"]')}function m(e,n){0===e?f(0):e===n-1&&f(document.documentElement.scrollHeight)}function v(e,n,t){var o=0,i=document.querySelector('[data-source-line="'.concat(e,'"]'));if(i)o=i.offsetTop;else{var c=function(e){for(var n=e-1,t=null;n>0&&!t;)(t=document.querySelector(d(n)))||(n-=1);return[n>=0?n:0,t?t.offsetTop:0]}(e),r=function(e,n){for(var t=e+1,o=null;t<n&&!o;)(o=document.querySelector(d(t)))||(t+=1);return[t<n?t:n-1,o?o.offsetTop:document.documentElement.scrollHeight]}(e,t);o=c[1]+(r[1]-c[1])*(e-c[0])/(r[0]-c[0])}f(o-document.documentElement.clientHeight*n)}var h={relative:function(e){var n=e.cursor,t=e.winline,o=e.winheight,i=e.len,c=n-1,r=t/o;0===c||c===i-1?m(c,i):v(c,r,i)},middle:function(e){var n=e.cursor,t=e.len,o=n-1;0===o||o===t-1?m(o,t):v(o,.5,t)},top:function(e){var n=e.cursor,t=e.winline,o=e.len,i=n-1;0===i||i===o-1?m(i,o):v(i=n-t,0,o)}},w=t(7696),g={content:[],isActive:!0,winline:1,winheight:800,cursor:[1,1],theme:"light",name:"Test"},_=function(e){var n=e.winline,t=e.winheight,o=e.content,i=e.cursor,c=e.isActive,r=e.options;c&&!r.disable_sync_scroll&&h[r.sync_scroll_type||"middle"]({cursor:i[1],winline:n,winheight:t,len:o.length})},p=function(e){var n=e.newContent,t=e.refreshContent,c=e.md,r=e.state,u=e.setState,l=e.articleTitle;u((0,o.Z)((0,i.Z)((0,o.Z)({},r),{title:null===l||void 0===l?void 0:l.title,slug:null===l||void 0===l?void 0:l.slug}),t?{content:c.render(n)}:{}))},T=function(e){var n=e.md,t=e.options,o=e.setSlug,i=(0,c.Z)(u.useState({content:[]}),2),l=i[0],a=i[1],f=u.useMemo((function(){return s()()}),[]);return u.useEffect((function(){var e=void 0,i="",c=void 0,r=function(){console.log("close"),window.closet()},u=function(r){var u=r.winline,s=r.winheight,d=r.content,m=r.cursor,v=r.isActive,h=r.articleTitle,w=d.join("\n"),g=i!==w;i=w,o(null===h||void 0===h?void 0:h.slug);var T={newContent:w,refreshContent:g,state:l,setState:a,md:n,articleTitle:h},y={winline:u,winheight:s,content:d,cursor:m,isActive:v,options:t};i?g?(e&&clearTimeout(e),c&&clearTimeout(c),c=setTimeout((function(){document.querySelectorAll("[data-z-article-name]").forEach((function(e){var n=e.getAttribute("data-z-article-name");e.removeAttribute("data-z-article-name"),e.removeAttribute("href"),e.onclick=function(){return function(e){return f.emit("change_page",e)}(n)},e.classList.add("zortex-local-link")}))}),1e3),e=setTimeout((function(){p(T),_(y)}),16)):_(y):(p(T),_(y))};u(g),f.on("connect",(function(){})),f.on("disconnect",(function(){})),f.on("close",r),f.on("close_page",r),f.on("refresh_content",u)}),[]),u.useEffect((function(){try{mermaid.initialize(t.maid||{}),mermaid.init(void 0,document.querySelectorAll(".mermaid"))}catch(e){}w.uy.render(),(0,w.$O)(),(0,w.sX)(),(0,w.kt)()}),[l.refreshContent]),(0,r.jsx)("section",{className:"markdown-body",dangerouslySetInnerHTML:{__html:l.content}})};function y(){var e=(0,w.HU)(),n=(0,c.Z)(u.useState(null),2),t=n[0],o=n[1];return(0,r.jsx)(a.Z,{articleSlug:t,children:(0,r.jsx)(T,{md:e,options:{},setSlug:o})})}},7101:function(){}},function(e){e.O(0,[774,144,730,259,872,923,487,888,179],(function(){return n=4169,e(e.s=n);var n}));var n=e.O();_N_E=n}]);