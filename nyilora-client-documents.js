// Private onboarding documents. Storage and database policies enforce access.
const NYILORA_DOCUMENT_BUCKET='nyilora-client-documents';
const NYILORA_DOCUMENT_TYPES=[
  ['client_passport','Client passport photo'],['client_id_front','Client ID — front'],
  ['client_id_back','Client ID — back'],['guarantor_passport','Guarantor passport photo'],
  ['guarantor_id_front','Guarantor ID — front'],['guarantor_id_back','Guarantor ID — back']
];
const pendingClientDocumentUploads=new Map();
function clientDocumentInputs(prefix='onboardDoc'){
  return `<h3 style="margin:16px 0 8px">Client &amp; Guarantor Documents</h3>
    <p style="font-size:12px;color:var(--text-secondary)">Attach passport photos and both sides of each ID. JPG, PNG or WEBP; ID copies may also be PDF. Maximum 8 MB per file.</p>
    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,240px),1fr));gap:12px">
    ${NYILORA_DOCUMENT_TYPES.map(([kind,label])=>`<div class="form-group"><label for="${prefix}_${kind}">${label}</label>
      <input class="input" style="max-width:100%" id="${prefix}_${kind}" type="file" accept="image/jpeg,image/png,image/webp${kind.endsWith('passport')?'':',application/pdf'}"></div>`).join('')}</div>`;
}
function validateClientDocument(kind,file){
  if(!NYILORA_DOCUMENT_TYPES.some(([key])=>key===kind))throw new Error('Unknown document type');
  const extensions={'image/jpeg':'jpg','image/png':'png','image/webp':'webp','application/pdf':'pdf'};
  const ext=extensions[file?.type];
  if(!ext||(kind.endsWith('passport')&&ext==='pdf'))throw new Error('Use JPG, PNG or WEBP for passport photos; ID copies may also be PDF.');
  if(!file.size||file.size>8*1024*1024)throw new Error(`${file.name}: maximum file size is 8 MB.`);
  return ext;
}
function selectedClientDocuments(prefix='onboardDoc'){
  const files=[];
  for(const[kind]of NYILORA_DOCUMENT_TYPES){
    const file=document.getElementById(`${prefix}_${kind}`)?.files?.[0];
    if(file){validateClientDocument(kind,file);files.push({kind,file});}
  }
  return files;
}
async function uploadPrivateClientDocument(clientId,kind,file){
  const ext=validateClientDocument(kind,file);
  const{data:old,error:readError}=await sb('nyilora_client_documents').select('object_path').eq('client_id',clientId).eq('kind',kind).maybeSingle();
  if(readError)throw readError;
  const path=`${currentUser.business_id}/${clientId}/${kind}/${crypto.randomUUID()}.${ext}`;
  const bucket=supabaseClient.storage.from(NYILORA_DOCUMENT_BUCKET);
  const{error:uploadError}=await bucket.upload(path,file,{contentType:file.type,upsert:false});
  if(uploadError)throw uploadError;
  const{error:saveError}=await sb('nyilora_client_documents').upsert({
    client_id:clientId,kind,business_id:currentUser.business_id,object_path:path,
    file_name:file.name,mime_type:file.type,file_size:file.size
  },{onConflict:'client_id,kind'});
  if(saveError){await bucket.remove([path]);throw saveError;}
  if(old?.object_path&&old.object_path!==path){
    const{error}=await bucket.remove([old.object_path]);
    if(error)console.warn('Previous document could not be removed',error.message);
  }
}
async function saveClientDocumentFiles(clientId,files){
  const failed=[];
  for(const item of files){
    try{await uploadPrivateClientDocument(clientId,item.kind,item.file);}
    catch(error){failed.push({...item,error:error.message||'Upload failed'});}
  }
  if(failed.length)pendingClientDocumentUploads.set(clientId,failed);
  else pendingClientDocumentUploads.delete(clientId);
  return failed;
}
async function openClientDocuments(clientId){
  try{
    const[{data:docs,error},{data:client,error:clientError}]=await Promise.all([
      sb('nyilora_client_documents').select('*').eq('client_id',clientId),
      sb('loan_clients').select('id,full_name,photo_path').eq('id',clientId).single()
    ]);
    if(error||clientError)throw error||clientError;
    const byKind=new Map((docs||[]).map(doc=>[doc.kind,doc]));
    const retry=pendingClientDocumentUploads.get(clientId)||[];
    openModal(`<h2>Documents — ${escapeHtml(client.full_name)}</h2>
      <p style="font-size:12px;color:var(--text-secondary)">Documents are private and available to authorized staff assigned to this client.</p>
      ${retry.length?`<div class="card" style="margin:12px 0"><p>Client saved. ${retry.length} attachment(s) still need uploading.</p>
        ${retry.map(item=>`<p>${escapeHtml(NYILORA_DOCUMENT_TYPES.find(([key])=>key===item.kind)?.[1])}: ${escapeHtml(item.error)}</p>`).join('')}
        <button class="btn btn-primary btn-sm" onclick="retryClientDocuments('${clientId}',this)">Retry pending uploads</button></div>`:''}
      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,240px),1fr));gap:12px">
      ${NYILORA_DOCUMENT_TYPES.map(([kind,label])=>{const doc=byKind.get(kind);const legacy=kind==='client_passport'&&!doc&&client.photo_path;
        return `<div class="card" style="padding:12px;min-width:0"><strong>${label}</strong>
          <p style="font-size:12px;overflow-wrap:anywhere">${doc?escapeHtml(doc.file_name):legacy?'Existing client photo':'Not yet attached'}</p>
          ${doc?`<button class="btn btn-outline btn-sm" onclick="viewPrivateClientDocument('${clientId}','${kind}')">View / Download</button>`:
            legacy?`<button class="btn btn-outline btn-sm" onclick="viewPrivateClientPhoto('${escapeHtml(client.photo_path)}')">View existing photo</button>`:''}
          <label style="display:block;margin-top:10px;font-size:12px">${doc?'Replace attachment':'Attach file'}
            <input class="input" style="max-width:100%" type="file" accept="image/jpeg,image/png,image/webp${kind.endsWith('passport')?'':',application/pdf'}"
              onchange="attachClientDocument('${clientId}','${kind}',this)"></label></div>`;
      }).join('')}</div><div class="modal-actions"><button class="btn btn-outline" onclick="closeModal()">Close</button></div>`,true);
  }catch(error){toast('Could not load documents: '+error.message,'error');}
}
async function attachClientDocument(clientId,kind,input){
  const file=input?.files?.[0];if(!file)return;
  input.disabled=true;
  try{await uploadPrivateClientDocument(clientId,kind,file);toast('Document saved','success');await openClientDocuments(clientId);}
  catch(error){toast('Document upload failed: '+error.message,'error');input.disabled=false;}
}
async function retryClientDocuments(clientId,button){
  button.disabled=true;button.textContent='Uploading…';
  await saveClientDocumentFiles(clientId,pendingClientDocumentUploads.get(clientId)||[]);
  await openClientDocuments(clientId);
}
async function viewPrivateClientDocument(clientId,kind){
  const popup=window.open('about:blank','_blank');if(popup)popup.opener=null;
  try{
    const{data:doc,error}=await sb('nyilora_client_documents').select('object_path').eq('client_id',clientId).eq('kind',kind).single();
    if(error)throw error;
    const{data,error:linkError}=await supabaseClient.storage.from(NYILORA_DOCUMENT_BUCKET).createSignedUrl(doc.object_path,60);
    if(linkError)throw linkError;
    if(popup)popup.location.replace(data.signedUrl);
    else openModal(`<h2>Document ready</h2><a class="btn btn-primary" href="${escapeHtml(data.signedUrl)}" target="_blank" rel="noopener noreferrer">Open document</a><p>This link expires in one minute.</p>`);
  }catch(error){if(popup)popup.close();toast('Could not open document: '+error.message,'error');}
}
