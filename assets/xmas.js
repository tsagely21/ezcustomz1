/* CHRISTMAS SALE + DECOR: edit off/end here. After end the sale and all decor switch off on their own.
   To remove: delete this file, xmas.css and the two tags before </head> in index, reviews and gallery. */
window.XMAS=(function(){
var off=150,end='2026-12-25',today=new Date().toLocaleDateString('en-CA',{timeZone:'America/Chicago'}),live=today<=end;
if(!live)return{off:off,end:end,live:false};
document.documentElement.classList.add('xmas');
var still=matchMedia('(prefers-reduced-motion:reduce)').matches;

/* string of bulbs: drawn as one SVG so it can repeat across any width */
function lights(){var c=['#ff3b4e','#2fe07a','#ffd34d','#58b8ff'],n=c.length*2,w=88,o='<svg class="xl-s" width="'+w*n+'" height="44" viewBox="0 0 '+w*n+' 44" aria-hidden="true"><path d="M0 6'+Array.from({length:n},function(_,i){return' Q'+(w*i+w/2)+' 26 '+w*(i+1)+' 6'}).join('')+'" fill="none" stroke="#3f6b52" stroke-width="2.5"/>';
  for(var i=0;i<n;i++){var x=w*i+w/2,k=c[i%c.length];o+='<g class="xb" style="--c:'+k+';animation-delay:'+(i%3)*.5+'s"><rect x="'+(x-3.5)+'" y="13" width="7" height="7" rx="1.5" fill="#20382b"/><path d="M'+x+' 19c6 4 7.500 10 5 14a5.800 5.800 0 0 1-10 0c-2.500-4-1-10 5-14z" fill="'+k+'"/></g>'}
  o+='</svg>';return'<div class="xl" aria-hidden="true">'+o+o+o+o+o+o+'</div>'}

var HAT='<svg class="xhat" viewBox="0 0 64 56" aria-hidden="true"><path d="M8 42C10 20 24 5 42 7c8 1 13 7 15 15-5-4-9-5-13-4 3 7 4 15 4 24z" fill="#e0202f"/><path d="M26 11c-8 6-13 17-14 30h6c1-12 4-22 8-30z" fill="#b5101f" opacity=".55"/><rect x="3" y="39" width="50" height="13" rx="6.500" fill="#fff"/><circle cx="57" cy="24" r="6.500" fill="#fff"/></svg>';
function orn(cls,col,len){return'<div class="xo '+cls+'" aria-hidden="true"><i style="height:'+len+'px"></i><svg viewBox="0 0 48 58"><rect x="19" y="1" width="10" height="8" rx="2" fill="#d9b24c"/><circle cx="24" cy="33" r="23" fill="'+col+'"/><path d="M3 27c12 6 30 6 42 0M3 39c12 6 30 6 42 0" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="2.500"/><ellipse cx="16" cy="23" rx="5" ry="7" fill="#fff" opacity=".4"/></svg></div>'}
var GIFT=function(cls,a,b){return'<svg class="xg '+cls+'" viewBox="0 0 64 64" aria-hidden="true"><rect x="6" y="24" width="52" height="38" rx="3" fill="'+a+'"/><rect x="2" y="15" width="60" height="13" rx="3" fill="'+a+'"/><rect x="2" y="23" width="60" height="5" fill="#000" opacity=".16"/><rect x="27" y="15" width="10" height="47" fill="'+b+'"/><path d="M32 15C22 2 8 4 13 11c3 4 12 4 19 4zm0 0C42 2 56 4 51 11c-3 4-12 4-19 4z" fill="'+b+'"/></svg>'};
var SLEIGH='<svg viewBox="0 0 340 90" aria-hidden="true" fill="#f4f1ff"><g transform="translate(0 0)" fill="none" stroke="#f4f1ff" stroke-width="3.2" stroke-linecap="round"><path d="M34 52q18-6 36 0" stroke-width="13"/><path d="M34 50 24 36" stroke-width="7"/><path d="M12 33h12" stroke-width="8"/><path d="M24 30l3-17M26 20l-9-7M27 14l7-7M21 30l-5-13M18 23l-7-3" stroke-width="2.2"/><path d="M36 58 26 75M43 59l-8 19M64 58l7 18M70 57l10 16M76 46l7-5"/><circle cx="8" cy="33" r="4" fill="#ff3b4e" stroke="none"/></g><g transform="translate(84 0)" fill="none" stroke="#f4f1ff" stroke-width="3.2" stroke-linecap="round"><path d="M34 52q18-6 36 0" stroke-width="13"/><path d="M34 50 24 36" stroke-width="7"/><path d="M12 33h12" stroke-width="8"/><path d="M24 30l3-17M26 20l-9-7M27 14l7-7M21 30l-5-13M18 23l-7-3" stroke-width="2.2"/><path d="M36 58 26 75M43 59l-8 19M64 58l7 18M70 57l10 16M76 46l7-5"/></g><path d="M78 52h8m70 0q10 2 24 10" fill="none" stroke="#f4f1ff" stroke-width="1.500"/><path d="M178 42h86c10 0 16-8 28-12l3 5c-9 6-11 26-27 32h-74c-10 0-14-13-16-25z"/><path d="M180 78h102c8 0 14-3 20-9" fill="none" stroke="#f4f1ff" stroke-width="4" stroke-linecap="round"/><path d="M196 67v11m56-11v11" stroke="#f4f1ff" stroke-width="3"/><circle cx="222" cy="22" r="8"/><path d="M212 44c0-13 5-18 11-18s13 6 14 18zM216 17c3-11 12-15 18-8l5 7-5 1c-4-3-10-2-18 0z"/><path d="M240 42c1-10 11-16 22-13l5 13z"/></svg>';

function days(){var d=Math.ceil((new Date(end+'T23:59:59')-new Date())/864e5);return d<=1?'Last day':d+' days left'}
function ready(){
  var b=document.body,h=document.querySelector('header'),hero=document.querySelector('.hero'),hi=document.querySelector('.hero-in');
  var q=hero?'#quote':'index.html#quote';
  /* sale strip on every page */
  var st=document.createElement('a');st.className='xstrip';st.href=q;st.innerHTML='<b>Christmas Sale</b><span>$'+off+' off starlights, $100 off ambient lighting</span><em>'+days()+'</em>';
  if(h){h.parentNode.insertBefore(st,h);h.insertAdjacentHTML('afterend',lights());var lg=h.querySelector('.logo');if(lg)lg.insertAdjacentHTML('beforeend',HAT)}
  /* hero: headline tag, ornaments, flying sleigh */
  if(hero){if(hi)hi.insertAdjacentHTML('afterbegin','<p class="xtag"><span>Christmas Sale</span> $'+off+' off, through Dec 25</p>');
    hero.insertAdjacentHTML('beforeend',orn('o1','#e0202f',54)+orn('o2','#1fae5f',110)+orn('o3','#e9b93a',24)+'<div class="xsl">'+SLEIGH+'</div>')}
  /* gifts + snowdrift at the bottom of the page */
  var f=document.querySelector('footer');if(f){f.classList.add('xf');f.insertAdjacentHTML('beforebegin','<div class="xdrift" aria-hidden="true"><div class="xgifts">'+GIFT('a','#e0202f','#ffd34d')+GIFT('b','#1fae5f','#fff')+GIFT('c','#7a35ff','#ff8fb0')+'</div><svg viewBox="0 0 1440 70" preserveAspectRatio="none"><path d="M0 70V34c110-30 220-30 340-8s230 26 360 2 250-30 380-6 240 24 360 2v48z" fill="#f4f7ff"/></svg></div>')}
  if(!still)snow();
}
/* one fixed canvas for the whole page: light snowfall that pauses when the tab is hidden */
function snow(){var c=document.createElement('canvas'),x=c.getContext('2d'),W,H,dpr=Math.min(devicePixelRatio||1,2),F=[];c.className='xsnow';c.setAttribute('aria-hidden','true');document.body.appendChild(c);
  function rs(){W=innerWidth;H=innerHeight;c.width=W*dpr;c.height=H*dpr;x.setTransform(dpr,0,0,dpr,0,0)}rs();addEventListener('resize',rs);
  for(var n=W<700?28:60,i=0;i<n;i++)F.push({x:Math.random()*W,y:Math.random()*H,r:.8+Math.random()*2.4,s:.25+Math.random()*.7,p:Math.random()*6.3,o:.35+Math.random()*.55});
  var qs=document.getElementById('quote');if(qs&&window.IntersectionObserver)new IntersectionObserver(function(e){c.style.opacity=e[0].isIntersecting?.35:1},{threshold:.15}).observe(qs);
  var t0=0;(function f(t){requestAnimationFrame(f);if(document.hidden)return;var dt=Math.min(40,t-t0||16)/16;t0=t;x.clearRect(0,0,W,H);x.fillStyle='#fff';
    F.forEach(function(a){a.y+=a.s*dt;a.x+=Math.sin(t/1400+a.p)*.3*dt;if(a.y>H+4){a.y=-4;a.x=Math.random()*W}x.globalAlpha=a.o;x.beginPath();x.arc(a.x,a.y,a.r,0,6.3);x.fill()})})(0)}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready);else ready();
return{off:off,end:end,live:true};
})();
